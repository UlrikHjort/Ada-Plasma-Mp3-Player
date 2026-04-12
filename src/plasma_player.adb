-- ***************************************************************************
--                   Plasma Player - main
--
--           Copyright (C) 2026 By Ulrik Hørlyk Hjort
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ***************************************************************************
with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Calendar;
with Ada.Numerics;
with Ada.Numerics.Discrete_Random;
with Ada.Numerics.Elementary_Functions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Wide_Wide_Characters.Handling;
with Ada.Text_IO;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

with C_Bridge;

procedure Plasma_Player is
   use Ada.Numerics.Elementary_Functions;
   use Ada.Characters.Handling;
   use Ada.Wide_Wide_Characters.Handling;
   use Ada.Strings;
   use Ada.Strings.Fixed;
   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type Interfaces.C.size_t;
   use type Interfaces.C.unsigned;
   use type Interfaces.C.Strings.chars_ptr;
   use type Interfaces.Unsigned_32;
   use type System.Address;

   Default_Window_Width  : constant Positive := 960;
   Default_Window_Height : constant Positive := 540;

   Sample_Rate      : constant := 44_100;
   Channels         : constant := 2;
   Bytes_Per_Sample : constant := 2;
   Bytes_Per_Frame  : constant := Channels * Bytes_Per_Sample;

   Chunk_Bytes       : constant := 32_768;
   Target_Queue      : constant := Sample_Rate * Bytes_Per_Frame / 2;
   Analysis_Size     : constant := 1_024;
   Spectrum_Bars     : constant := 48;
   History_Seconds   : constant := 6;
   History_Size      : constant := Sample_Rate * History_Seconds;
   Frame_Delay_MS    : constant Interfaces.C.unsigned := 16;
   Export_FPS        : constant := 60;
   About_Width       : constant := 520;
   About_Height      : constant := 220;

   type Mono_Buffer is array (Natural range 0 .. History_Size - 1) of Float;
   type Window_Buffer is array (Natural range 0 .. Analysis_Size - 1) of Float;
   type Spectrum_Buffer is array (Natural range 0 .. Spectrum_Bars - 1) of Float;
   type Pixel_Buffer is
      array (Natural range <>) of aliased Interfaces.Unsigned_32;
   subtype About_Pixel_Buffer is Pixel_Buffer (0 .. About_Width * About_Height - 1);
    type Chunk_Buffer is
      array (Natural range 0 .. (Chunk_Bytes / Bytes_Per_Sample) - 1) of
        aliased Interfaces.C.short;
    type Coord_X is array (Natural range <>) of Float;
    type Coord_Y is array (Natural range <>) of Float;
   type Pixel_Buffer_Access is access all Pixel_Buffer;
   type Coord_X_Access is access all Coord_X;
   type Coord_Y_Access is access all Coord_Y;
   type Plasma_Mode is
     (Classic, Rings, Tunnel, Spiral, Grid, Wave, Vortex, Ripple, Mosaic,
       Helix, Lattice, Pulse, Interference, Metaball, Kaleidoscope, Warp,
       Starburst, Aurora_Flow, Liquid_Marble, Hex_Field, Fractal_Pulse,
       Lightning_Veins, Orbital_Wells);
   type Color_Mode is
      (Neon, Fire, Ocean, Mono, Aurora, Sunset, Ice, Acid, Ember, Forest,
       Candy, Violet, Gold, Cyberpunk, Toxic, Infrared, Deep_Space, Chrome,
       Nightclub);

   package Random_Plasma_Modes is new Ada.Numerics.Discrete_Random (Plasma_Mode);
   package Random_Color_Modes is new Ada.Numerics.Discrete_Random (Color_Mode);

   Default_Auto_Switch_Cooldown_MS : constant Natural := 900;
   Color_Strobe_Interval_MS        : constant Natural := 70;
   Intro_Overlay_Duration_MS       : constant Natural := 5_000;
   Intro_Overlay_Fade_MS           : constant Natural := 1_000;

   History  : Mono_Buffer := (others => 0.0);
   Hann     : Window_Buffer := (others => 0.0);
   Spectrum : Spectrum_Buffer := (others => 0.0);
   Pixels   : Pixel_Buffer_Access := null;
   Chunk    : aliased Chunk_Buffer := (others => 0);
   X_Pos    : Coord_X_Access := null;
   Y_Pos    : Coord_Y_Access := null;
   About_Pixels : aliased About_Pixel_Buffer := (others => 16#FF000000#);
   Mode_Generator  : Random_Plasma_Modes.Generator;
   Color_Generator : Random_Color_Modes.Generator;

   Total_Frames_Enqueued : Long_Long_Integer := 0;
   Paused                : Boolean := False;
   Show_Spectrum         : Boolean := False;
   Current_Mode          : Plasma_Mode := Classic;
   Current_Colors        : Color_Mode := Neon;
   Auto_Switching        : Boolean := True;
   Color_Strobe_Enabled  : Boolean := False;
   Auto_Switch_Cooldown_MS : Natural := Default_Auto_Switch_Cooldown_MS;
   Bass_Level            : Float := 0.0;
   Mid_Level             : Float := 0.0;
   Treble_Level          : Float := 0.0;
   Previous_Energy       : Float := 0.0;
   Energy_Flux           : Float := 0.0;
   Last_Auto_Switch_MS   : Natural := 0;
   Last_Color_Strobe_MS  : Natural := 0;
   About_Visible         : Boolean := False;
   About_Opened_MS       : Natural := 0;
   Record_Mode_Enabled   : Boolean := False;
   Intro_Overlay_Enabled : Boolean := False;
   Input_Path_Arg        : Unbounded_String := To_Unbounded_String ("t.mp3");
   Output_Path_Arg       : Unbounded_String := To_Unbounded_String ("");
   Intro_Title_Arg       : Unbounded_String := To_Unbounded_String ("");
   Intro_Name_Arg        : Unbounded_String := To_Unbounded_String ("");
   Window_Width          : Positive := Default_Window_Width;
   Window_Height         : Positive := Default_Window_Height;
   Intro_Overlay_Start_MS: Natural := 0;

   O_Slash_Char     : constant Wide_Wide_Character := Wide_Wide_Character'Val (16#00D8#);
   About_Title_Text : constant Wide_Wide_String := "ADA PLASMA PLAYER";
   About_Author_Text : constant Wide_Wide_String :=
      "BY ULRIK H" & O_Slash_Char & "RLYK HJORT - 2018";
   Default_Intro_Name_Text : constant Wide_Wide_String :=
      "ULRIK H" & O_Slash_Char & "RLYK HJORT";

   function Clamp_01 (Value : Float) return Float is
   begin
      if Value < 0.0 then
         return 0.0;
      elsif Value > 1.0 then
         return 1.0;
      else
         return Value;
      end if;
   end Clamp_01;

   function To_Byte (Value : Float) return Interfaces.Unsigned_32 is
   begin
      return Interfaces.Unsigned_32 (Integer (Clamp_01 (Value) * 255.0));
   end To_Byte;

   function Pack_RGBA (Red, Green, Blue : Float) return Interfaces.Unsigned_32 is
   begin
      return
        Interfaces.Shift_Left (16#FF#, 24)
        or Interfaces.Shift_Left (To_Byte (Red), 16)
        or Interfaces.Shift_Left (To_Byte (Green), 8)
        or To_Byte (Blue);
   end Pack_RGBA;

   function Bridge_Error return String is
      Ptr : constant Interfaces.C.Strings.chars_ptr := C_Bridge.Last_Error;
   begin
      if Ptr = Interfaces.C.Strings.Null_Ptr then
         return "unknown bridge error";
      end if;

      return Interfaces.C.Strings.Value (Ptr);
   end Bridge_Error;

   subtype Glyph_Row_String is String (1 .. 5);
   type Glyph_Rows is array (Natural range 0 .. 6) of Glyph_Row_String;

   procedure Fail (Message : String) is
   begin
      raise Program_Error with Message;
   end Fail;

   procedure Next_UTF8_Code_Point
     (Text  : String;
      Index : in out Positive;
      Code  : out Wide_Wide_Character)
   is
      function Is_Continuation (Value : Natural) return Boolean is
        (Value in 16#80# .. 16#BF#);

      B1 : constant Natural := Character'Pos (Text (Index));
      B2 : Natural;
      B3 : Natural;
      B4 : Natural;
      Value : Natural;
   begin
      if B1 < 16#80# then
         Code := Wide_Wide_Character'Val (B1);
         Index := Index + 1;
      elsif
        B1 in 16#C2# .. 16#DF#
        and then Index + 1 <= Text'Last
      then
         B2 := Character'Pos (Text (Index + 1));
         if Is_Continuation (B2) then
            Value := (B1 mod 16#20#) * 16#40# + (B2 mod 16#40#);
            Code := Wide_Wide_Character'Val (Value);
            Index := Index + 2;
         else
            Code := '?';
            Index := Index + 1;
         end if;
      elsif
        B1 in 16#E0# .. 16#EF#
        and then Index + 2 <= Text'Last
      then
         B2 := Character'Pos (Text (Index + 1));
         B3 := Character'Pos (Text (Index + 2));
         if Is_Continuation (B2) and then Is_Continuation (B3) then
            Value :=
              (B1 mod 16#10#) * 16#1000#
              + (B2 mod 16#40#) * 16#40#
              + (B3 mod 16#40#);
            Code := Wide_Wide_Character'Val (Value);
            Index := Index + 3;
         else
            Code := '?';
            Index := Index + 1;
         end if;
      elsif
        B1 in 16#F0# .. 16#F4#
        and then Index + 3 <= Text'Last
      then
         B2 := Character'Pos (Text (Index + 1));
         B3 := Character'Pos (Text (Index + 2));
         B4 := Character'Pos (Text (Index + 3));
         if
           Is_Continuation (B2)
           and then Is_Continuation (B3)
           and then Is_Continuation (B4)
         then
            Value :=
              (B1 mod 16#08#) * 16#40000#
              + (B2 mod 16#40#) * 16#1000#
              + (B3 mod 16#40#) * 16#40#
              + (B4 mod 16#40#);
            Code := Wide_Wide_Character'Val (Value);
            Index := Index + 4;
         else
            Code := '?';
            Index := Index + 1;
         end if;
      else
         Code := '?';
         Index := Index + 1;
      end if;
   end Next_UTF8_Code_Point;

   function Decode_UTF8 (Text : String) return Wide_Wide_String is
      Count : Natural := 0;
      Scan  : Positive;
      Dummy : Wide_Wide_Character;
   begin
      if Text'Length = 0 then
         return "";
      end if;

      Scan := Text'First;
      while Scan <= Text'Last loop
         Next_UTF8_Code_Point (Text, Scan, Dummy);
         Count := Count + 1;
      end loop;

      declare
         Result : Wide_Wide_String (1 .. Count);
         Index  : Positive := Text'First;
      begin
         for Pos in Result'Range loop
            Next_UTF8_Code_Point (Text, Index, Result (Pos));
         end loop;

         return Result;
      end;
   end Decode_UTF8;

   function Normalize_Overlay_Text (Text : Wide_Wide_String) return Wide_Wide_String is
      Result : Wide_Wide_String (1 .. Natural'Max (1, Text'Length));
      Last   : Natural := 0;
      Previous_Space : Boolean := True;
      Upper : Wide_Wide_Character;
   begin
      for Ch of Text loop
         Upper := To_Upper (Ch);

         if
           Upper in 'A' .. 'Z'
           or else Upper in '0' .. '9'
           or else Upper = '-'
           or else Upper = O_Slash_Char
         then
            Last := Last + 1;
            Result (Last) := Upper;
            Previous_Space := False;
         elsif
           Upper = ' '
           or else Upper = '_'
           or else Upper = '.'
           or else Upper = '/'
           or else Upper = '\'
           or else Upper = '''
         then
            if not Previous_Space then
               Last := Last + 1;
               Result (Last) := ' ';
               Previous_Space := True;
            end if;
         end if;
      end loop;

      if Last = 0 then
         return "";
      elsif Result (Last) = ' ' then
         return Result (1 .. Last - 1);
      else
         return Result (1 .. Last);
      end if;
   end Normalize_Overlay_Text;

   function Intro_Author_Line return Wide_Wide_String is
      Name_Text : constant Wide_Wide_String :=
        (if Length (Intro_Name_Arg) = 0
         then ""
         else Normalize_Overlay_Text (Decode_UTF8 (To_String (Intro_Name_Arg))));
   begin
      if Name_Text'Length = 0 then
         return "";
      else
         return "BY " & Name_Text;
      end if;
   end Intro_Author_Line;

   function Intro_Title_From_Path (Path : String) return String is
      Start_Index : Positive := Path'First;
      Finish      : Natural := Path'Last;
      Result      : Unbounded_String;
      Previous_Space : Boolean := True;
   begin
      for Index in reverse Path'Range loop
         if Path (Index) = '/' then
            if Index < Path'Last then
               Start_Index := Index + 1;
            end if;
            exit;
         end if;
      end loop;

      if
        Finish >= Start_Index + 3
        and then To_Upper (Path (Finish - 3 .. Finish)) = ".MP3"
      then
         Finish := Finish - 4;
      end if;

      if Finish < Start_Index then
         return "UNTITLED";
      end if;

      for Ch of Path (Start_Index .. Finish) loop
         declare
            Upper : constant Character := To_Upper (Ch);
         begin
            if Upper in 'A' .. 'Z' or else Upper in '0' .. '9' then
               Append (Result, String'(1 => Upper));
               Previous_Space := False;
            elsif Ch = ' ' or else Ch = '_' or else Ch = '-' or else Ch = '.' then
               if not Previous_Space then
                  Append (Result, " ");
                  Previous_Space := True;
               end if;
            end if;
         end;
      end loop;

      declare
         Title : constant String := Trim (To_String (Result), Both);
      begin
         if Title'Length = 0 then
            return "UNTITLED";
         else
            return Title;
         end if;
      end;
   end Intro_Title_From_Path;

   procedure Parse_Window_Size (Spec : String) is
      Separator : Natural := 0;
   begin
      for Index in Spec'Range loop
         if Spec (Index) = 'x' or else Spec (Index) = 'X' then
            Separator := Index;
            exit;
         end if;
      end loop;

      if Separator = 0 or else Separator = Spec'First or else Separator = Spec'Last then
         Fail ("invalid --window-size value: " & Spec & " (expected WIDTHxHEIGHT)");
      end if;

      declare
         Width_Text  : constant String := Spec (Spec'First .. Separator - 1);
         Height_Text : constant String := Spec (Separator + 1 .. Spec'Last);
      begin
         begin
            Window_Width := Positive'Value (Width_Text);
            Window_Height := Positive'Value (Height_Text);
         exception
            when Constraint_Error =>
               Fail ("invalid --window-size value: " & Spec);
         end;
      end;
   end Parse_Window_Size;

   procedure Initialize_Render_Buffers is
   begin
      Pixels := new Pixel_Buffer (0 .. Window_Width * Window_Height - 1);
      Pixels.all := (others => 16#FF000000#);
      X_Pos := new Coord_X (0 .. Window_Width - 1);
      Y_Pos := new Coord_Y (0 .. Window_Height - 1);
   end Initialize_Render_Buffers;

   function Mode_Name (Mode : Plasma_Mode) return String is
   begin
      case Mode is
         when Classic =>
            return "Classic";
         when Rings =>
            return "Rings";
         when Tunnel =>
            return "Tunnel";
         when Spiral =>
            return "Spiral";
         when Grid =>
            return "Grid";
         when Wave =>
            return "Wave";
         when Vortex =>
            return "Vortex";
         when Ripple =>
            return "Ripple";
         when Mosaic =>
            return "Mosaic";
         when Helix =>
            return "Helix";
         when Lattice =>
            return "Lattice";
         when Pulse =>
            return "Pulse";
         when Interference =>
            return "Interference";
         when Metaball =>
            return "Metaball";
         when Kaleidoscope =>
            return "Kaleidoscope";
         when Warp =>
            return "Warp";
         when Starburst =>
            return "Starburst";
         when Aurora_Flow =>
            return "Aurora Flow";
         when Liquid_Marble =>
            return "Liquid Marble";
         when Hex_Field =>
            return "Hex Field";
         when Fractal_Pulse =>
            return "Fractal Pulse";
         when Lightning_Veins =>
            return "Lightning Veins";
         when Orbital_Wells =>
            return "Orbital Wells";
      end case;
   end Mode_Name;

   function Color_Name (Mode : Color_Mode) return String is
   begin
      case Mode is
         when Neon =>
            return "Neon";
         when Fire =>
            return "Fire";
         when Ocean =>
            return "Ocean";
         when Mono =>
            return "Mono";
         when Aurora =>
            return "Aurora";
         when Sunset =>
            return "Sunset";
         when Ice =>
            return "Ice";
         when Acid =>
            return "Acid";
         when Ember =>
            return "Ember";
         when Forest =>
            return "Forest";
         when Candy =>
            return "Candy";
         when Violet =>
            return "Violet";
         when Gold =>
            return "Gold";
         when Cyberpunk =>
            return "Cyberpunk";
         when Toxic =>
            return "Toxic";
         when Infrared =>
            return "Infrared";
         when Deep_Space =>
            return "Deep Space";
         when Chrome =>
            return "Chrome";
         when Nightclub =>
            return "Nightclub";
      end case;
   end Color_Name;

   function Auto_State_Name (Enabled : Boolean) return String is
   begin
      if Enabled then
         return "On";
      else
         return "Off";
      end if;
   end Auto_State_Name;

   function Window_Title return String is
   begin
      return
        "Ada Plasma Player / "
        & Mode_Name (Current_Mode)
        & " - "
        & Color_Name (Current_Colors);
   end Window_Title;

   procedure Update_Window_Title is
      Title : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Window_Title);
   begin
      C_Bridge.Set_Window_Title (Title);
      Interfaces.C.Strings.Free (Title);
   end Update_Window_Title;

   procedure Clear_About (Color : Interfaces.Unsigned_32) is
   begin
      About_Pixels := (others => Color);
   end Clear_About;

   function Color_Channel
     (Color : Interfaces.Unsigned_32;
      Shift : Natural) return Float
   is
      Masked : constant Interfaces.Unsigned_32 :=
        Interfaces.Shift_Right (Color, Shift) and Interfaces.Unsigned_32 (16#FF#);
   begin
      return Float (Integer (Masked)) / 255.0;
   end Color_Channel;

   function Blend_Color
     (Base_Color    : Interfaces.Unsigned_32;
      Overlay_Color : Interfaces.Unsigned_32;
      Opacity       : Float) return Interfaces.Unsigned_32
   is
      Alpha : constant Float := Clamp_01 (Opacity);
   begin
      if Alpha <= 0.0 then
         return Base_Color;
      elsif Alpha >= 1.0 then
         return Overlay_Color;
      else
         return
           Pack_RGBA
             (Color_Channel (Base_Color, 16) * (1.0 - Alpha)
                + Color_Channel (Overlay_Color, 16) * Alpha,
              Color_Channel (Base_Color, 8) * (1.0 - Alpha)
                + Color_Channel (Overlay_Color, 8) * Alpha,
              Color_Channel (Base_Color, 0) * (1.0 - Alpha)
                + Color_Channel (Overlay_Color, 0) * Alpha);
      end if;
   end Blend_Color;

   procedure Fill_Rect
     (Buffer      : in out Pixel_Buffer;
      Buffer_Width  : Positive;
      Buffer_Height : Positive;
      X           : Natural;
      Y           : Natural;
      Rect_Width  : Natural;
      Rect_Height : Natural;
      Color       : Interfaces.Unsigned_32;
      Opacity     : Float := 1.0)
   is
      X_Last : Natural;
      Y_Last : Natural;
      Index  : Natural;
   begin
      if
        Rect_Width = 0
        or else Rect_Height = 0
        or else X >= Buffer_Width
        or else Y >= Buffer_Height
      then
         return;
      end if;

      X_Last := Natural'Min (Buffer_Width - 1, X + Rect_Width - 1);
      Y_Last := Natural'Min (Buffer_Height - 1, Y + Rect_Height - 1);

      for Y_Pos in Y .. Y_Last loop
         for X_Pos in X .. X_Last loop
            Index := Y_Pos * Buffer_Width + X_Pos;
            Buffer (Index) := Blend_Color (Buffer (Index), Color, Opacity);
         end loop;
      end loop;
   end Fill_Rect;

   function Glyph_For (Ch : Wide_Wide_Character) return Glyph_Rows is
   begin
      case Ch is
         when 'A' => return ("01110", "10001", "10001", "11111", "10001", "10001", "10001");
         when 'B' => return ("11110", "10001", "10001", "11110", "10001", "10001", "11110");
         when 'C' => return ("01110", "10001", "10000", "10000", "10000", "10001", "01110");
         when 'D' => return ("11110", "10001", "10001", "10001", "10001", "10001", "11110");
         when 'E' => return ("11111", "10000", "10000", "11110", "10000", "10000", "11111");
         when 'F' => return ("11111", "10000", "10000", "11110", "10000", "10000", "10000");
         when 'G' => return ("01110", "10001", "10000", "10111", "10001", "10001", "01110");
         when 'H' => return ("10001", "10001", "10001", "11111", "10001", "10001", "10001");
         when 'I' => return ("11111", "00100", "00100", "00100", "00100", "00100", "11111");
         when 'J' => return ("00111", "00010", "00010", "00010", "10010", "10010", "01100");
         when 'K' => return ("10001", "10010", "10100", "11000", "10100", "10010", "10001");
         when 'L' => return ("10000", "10000", "10000", "10000", "10000", "10000", "11111");
         when 'M' => return ("10001", "11011", "10101", "10101", "10001", "10001", "10001");
         when 'N' => return ("10001", "11001", "10101", "10011", "10001", "10001", "10001");
         when 'O' => return ("01110", "10001", "10001", "10001", "10001", "10001", "01110");
         when 'P' => return ("11110", "10001", "10001", "11110", "10000", "10000", "10000");
         when 'Q' => return ("01110", "10001", "10001", "10001", "10101", "10010", "01101");
         when 'R' => return ("11110", "10001", "10001", "11110", "10100", "10010", "10001");
         when 'S' => return ("01111", "10000", "10000", "01110", "00001", "00001", "11110");
         when 'T' => return ("11111", "00100", "00100", "00100", "00100", "00100", "00100");
         when 'U' => return ("10001", "10001", "10001", "10001", "10001", "10001", "01110");
         when 'V' => return ("10001", "10001", "10001", "10001", "10001", "01010", "00100");
         when 'W' => return ("10001", "10001", "10001", "10101", "10101", "10101", "01010");
         when 'X' => return ("10001", "10001", "01010", "00100", "01010", "10001", "10001");
         when 'Y' => return ("10001", "10001", "01010", "00100", "00100", "00100", "00100");
         when 'Z' => return ("11111", "00001", "00010", "00100", "01000", "10000", "11111");
         when '0' => return ("01110", "10001", "10011", "10101", "11001", "10001", "01110");
         when '1' => return ("00100", "01100", "00100", "00100", "00100", "00100", "01110");
         when '2' => return ("01110", "10001", "00001", "00010", "00100", "01000", "11111");
         when '3' => return ("11110", "00001", "00001", "01110", "00001", "00001", "11110");
         when '4' => return ("00010", "00110", "01010", "10010", "11111", "00010", "00010");
         when '5' => return ("11111", "10000", "10000", "11110", "00001", "00001", "11110");
         when '6' => return ("01110", "10000", "10000", "11110", "10001", "10001", "01110");
         when '7' => return ("11111", "00001", "00010", "00100", "01000", "01000", "01000");
         when '8' => return ("01110", "10001", "10001", "01110", "10001", "10001", "01110");
         when '9' => return ("01110", "10001", "10001", "01111", "00001", "00001", "01110");
         when '-' => return ("00000", "00000", "00000", "11111", "00000", "00000", "00000");
         when ' ' => return ("00000", "00000", "00000", "00000", "00000", "00000", "00000");
         when O_Slash_Char =>
            return ("01110", "10011", "10101", "10101", "10101", "11001", "01110");
         when others =>
            return ("11111", "10001", "00100", "00100", "00100", "00000", "00100");
      end case;
   end Glyph_For;

   function Text_Width (Text : Wide_Wide_String; Scale : Positive) return Natural is
   begin
      if Text'Length = 0 then
         return 0;
      else
         return Text'Length * 6 * Scale - Scale;
      end if;
   end Text_Width;

   function Fit_Text_Scale
     (Text      : Wide_Wide_String;
      Max_Width : Natural;
      Preferred : Positive) return Positive
   is
   begin
      for Scale in reverse 1 .. Preferred loop
         if Text_Width (Text, Scale) <= Max_Width then
            return Scale;
         end if;
      end loop;

      return 1;
   end Fit_Text_Scale;

   procedure Draw_Glyph
     (Buffer : in out Pixel_Buffer;
      Buffer_Width  : Positive;
      Buffer_Height : Positive;
      Ch    : Wide_Wide_Character;
      X     : Natural;
      Y     : Natural;
      Scale : Positive;
      Color : Interfaces.Unsigned_32;
      Opacity : Float := 1.0)
   is
      Glyph : constant Glyph_Rows := Glyph_For (Ch);
   begin
      for Row in Glyph'Range loop
         for Col in Glyph (Row)'Range loop
            if Glyph (Row) (Col) = '1' then
               Fill_Rect
                 (Buffer       => Buffer,
                  Buffer_Width  => Buffer_Width,
                  Buffer_Height => Buffer_Height,
                  X            => X + (Col - Glyph (Row)'First) * Scale,
                  Y            => Y + Row * Scale,
                  Rect_Width   => Scale,
                  Rect_Height  => Scale,
                  Color        => Color,
                  Opacity      => Opacity);
            end if;
         end loop;
      end loop;
   end Draw_Glyph;

   procedure Draw_Text
      (Buffer      : in out Pixel_Buffer;
       Buffer_Width  : Positive;
       Buffer_Height : Positive;
       Text        : Wide_Wide_String;
       X           : Natural;
       Y           : Natural;
       Scale       : Positive;
       Color       : Interfaces.Unsigned_32;
      Visible_Chars : Natural := Natural'Last;
      Time_Sec      : Float := 0.0;
      Wave_Amplitude : Float := 0.0;
      Wave_Speed     : Float := 0.0;
      Wave_Phase     : Float := 0.0;
      Opacity        : Float := 1.0)
   is
      Draw_Count : constant Natural := Natural'Min (Visible_Chars, Text'Length);
      Glyph_Y    : Integer;
   begin
      for Index in 0 .. Draw_Count - 1 loop
         Glyph_Y :=
           Integer (Y)
           + Integer
               (Wave_Amplitude
                * Sin (Time_Sec * Wave_Speed + Float (Index) * Wave_Phase));
         Draw_Glyph
           (Buffer       => Buffer,
            Buffer_Width  => Buffer_Width,
            Buffer_Height => Buffer_Height,
            Ch           => Text (Text'First + Index),
            X            => X + Index * 6 * Scale,
            Y            => Natural'Max (0, Glyph_Y),
            Scale        => Scale,
            Color        => Color,
            Opacity      => Opacity);
      end loop;
   end Draw_Text;

   procedure Render_Intro_Overlay (Now_MS : Natural; Time_Sec : Float) is
      Elapsed : Natural;
   begin
      if not Intro_Overlay_Enabled then
         return;
      end if;

      if Now_MS < Intro_Overlay_Start_MS then
         Elapsed := 0;
      else
         Elapsed := Now_MS - Intro_Overlay_Start_MS;
      end if;

      if Elapsed >= Intro_Overlay_Duration_MS then
         return;
      end if;

      declare
         Fade_Start    : constant Natural :=
           Intro_Overlay_Duration_MS - Intro_Overlay_Fade_MS;
         Alpha         : constant Float :=
           (if Elapsed < Fade_Start then 1.0
            else 1.0 - Float (Elapsed - Fade_Start) / Float (Intro_Overlay_Fade_MS));
         Margin        : constant Natural := Natural'Max (12, Window_Width / 18);
         Available_W   : constant Natural := Natural'Max (1, Window_Width - Margin * 2);
         Padding       : constant Natural := 14;
         Title_Text    : constant Wide_Wide_String :=
           Decode_UTF8 (To_String (Intro_Title_Arg));
         Author_Text   : constant Wide_Wide_String := Intro_Author_Line;
         Show_Author   : constant Boolean := Author_Text'Length > 0;
         Title_Scale   : constant Positive :=
           Fit_Text_Scale (Title_Text, Natural'Max (1, Available_W - Padding * 2), 5);
         Author_Scale  : constant Positive :=
           (if Title_Scale > 3 then 3 else Title_Scale);
         Title_Width_Px  : constant Natural := Text_Width (Title_Text, Title_Scale);
         Author_Width_Px : constant Natural :=
           (if Show_Author then Text_Width (Author_Text, Author_Scale) else 0);
         Content_Width : constant Natural :=
           (if Title_Width_Px > Author_Width_Px then Title_Width_Px else Author_Width_Px);
         Gap          : constant Natural :=
           (if Show_Author then Natural'Max (10, Title_Scale * 2) else 0);
         Panel_Width  : constant Natural :=
           Natural'Min (Available_W, Content_Width + Padding * 2);
         Panel_Height : constant Natural :=
           Padding * 2
           + 7 * Title_Scale
           + (if Show_Author then Gap + 7 * Author_Scale else 0);
         Panel_X      : constant Natural := (Window_Width - Panel_Width) / 2;
         Panel_Y      : constant Natural :=
           Natural'Max
             (16,
             (if Window_Height > Panel_Height
              then (Window_Height - Panel_Height) / 6
              else 0));
         Title_X      : constant Natural :=
           (if Panel_Width > Title_Width_Px
            then Panel_X + (Panel_Width - Title_Width_Px) / 2
            else Panel_X + Padding / 2);
         Title_Y      : constant Natural := Panel_Y + Padding;
         Author_X     : constant Natural :=
           (if Panel_Width > Author_Width_Px
            then Panel_X + (Panel_Width - Author_Width_Px) / 2
            else Panel_X + Padding / 2);
         Author_Y     : constant Natural := Title_Y + 7 * Title_Scale + Gap;
      begin
         Draw_Text
            (Buffer        => Pixels.all,
             Buffer_Width  => Window_Width,
             Buffer_Height => Window_Height,
             Text          => Title_Text,
             X             => Title_X + Title_Scale,
             Y             => Title_Y + Title_Scale,
             Scale         => Title_Scale,
             Color         => Pack_RGBA (0.0, 0.0, 0.0),
             Time_Sec      => Time_Sec,
             Wave_Amplitude => Float (Title_Scale) * 1.8,
             Wave_Speed     => 4.8,
             Wave_Phase     => 0.55,
             Opacity       => 0.55 * Alpha);
         Draw_Text
            (Buffer        => Pixels.all,
            Buffer_Width  => Window_Width,
            Buffer_Height => Window_Height,
            Text          => Title_Text,
            X             => Title_X,
            Y             => Title_Y,
            Scale         => Title_Scale,
            Color         => Pack_RGBA (0.92, 0.95, 1.0),
            Time_Sec      => Time_Sec,
            Wave_Amplitude => Float (Title_Scale) * 1.8,
            Wave_Speed     => 4.8,
            Wave_Phase     => 0.55,
            Opacity        => Alpha);

         if Show_Author then
            Draw_Text
              (Buffer        => Pixels.all,
               Buffer_Width  => Window_Width,
               Buffer_Height => Window_Height,
               Text          => Author_Text,
               X             => Author_X + Author_Scale,
               Y             => Author_Y + Author_Scale,
               Scale         => Author_Scale,
               Color         => Pack_RGBA (0.0, 0.0, 0.0),
               Time_Sec      => Time_Sec,
               Wave_Amplitude => Float (Author_Scale) * 1.5,
               Wave_Speed     => 3.4,
               Wave_Phase     => 0.45,
               Opacity       => 0.45 * Alpha);
            Draw_Text
              (Buffer        => Pixels.all,
               Buffer_Width  => Window_Width,
               Buffer_Height => Window_Height,
               Text          => Author_Text,
               X             => Author_X,
               Y             => Author_Y,
               Scale         => Author_Scale,
               Color         => Pack_RGBA (0.72, 0.82, 0.96),
               Time_Sec      => Time_Sec,
               Wave_Amplitude => Float (Author_Scale) * 1.5,
               Wave_Speed     => 3.4,
               Wave_Phase     => 0.45,
               Opacity       => 0.92 * Alpha);
         end if;
      end;
   end Render_Intro_Overlay;

   procedure Hide_About_Window is
   begin
      if About_Visible then
         C_Bridge.Close_About_Window;
         About_Visible := False;
      end if;
   end Hide_About_Window;

   procedure Toggle_About_Window (Now_MS : Natural) is
      Title : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String ("Ada Plasma Player - About");
   begin
      if About_Visible then
         Hide_About_Window;
      else
         if
           C_Bridge.Open_About_Window
             (Title  => Title,
              Width  => Interfaces.C.int (About_Width),
              Height => Interfaces.C.int (About_Height))
           /= 0
         then
            Interfaces.C.Strings.Free (Title);
            Fail ("opening about window failed: " & Bridge_Error);
         end if;

         About_Visible := True;
         About_Opened_MS := Now_MS;
      end if;

      Interfaces.C.Strings.Free (Title);
   end Toggle_About_Window;

   procedure Render_About_Window (Now_MS : Natural) is
      Time_Sec        : constant Float := Float (Now_MS) / 1_000.0;
      Elapsed         : constant Natural := Now_MS - About_Opened_MS;
      Title_Scale     : constant Positive := 4;
      Author_Scale    : constant Positive := 2;
      Title_Chars     : constant Natural :=
        Natural'Min (About_Title_Text'Length, Elapsed / 70 + 1);
      Title_X         : constant Natural :=
        (About_Width - Text_Width (About_Title_Text, Title_Scale)) / 2;
      Author_X        : constant Natural :=
        (About_Width - Text_Width (About_Author_Text, Author_Scale)) / 2;
      Title_Y         : constant Natural :=
        36 + Natural (2.0 * (1.0 + Sin (Time_Sec * 5.0)));
      Author_Color    : constant Interfaces.Unsigned_32 :=
        Pack_RGBA (0.86, 0.86, 0.92);
      Title_Color     : constant Interfaces.Unsigned_32 :=
        Pack_RGBA
          (0.55 + 0.35 * (0.5 + 0.5 * Sin (Time_Sec * 2.7)),
           0.35 + 0.45 * (0.5 + 0.5 * Sin (Time_Sec * 3.3 + 1.2)),
           0.55 + 0.35 * (0.5 + 0.5 * Sin (Time_Sec * 2.1 + 2.1)));
      Back_Red        : Float;
      Back_Green      : Float;
      Back_Blue       : Float;
      Value           : Float;
      Norm            : Float;
   begin
      for Y_Index in 0 .. About_Height - 1 loop
         for X_Index in 0 .. About_Width - 1 loop
            Value :=
              (Sin (Float (X_Index) / 19.0 + Time_Sec * 1.8)
               + Sin (Float (Y_Index) / 17.0 - Time_Sec * 1.6)
               + Sin ((Float (X_Index) + Float (Y_Index)) / 29.0 + Time_Sec * 1.1))
              / 3.0;
            Norm := 0.5 + 0.5 * Value;
            Back_Red := 0.05 + Norm * 0.12;
            Back_Green := 0.04 + Norm * 0.08;
            Back_Blue := 0.10 + Norm * 0.22;
            About_Pixels (Y_Index * About_Width + X_Index) :=
              Pack_RGBA (Back_Red, Back_Green, Back_Blue);
         end loop;
      end loop;

      Fill_Rect
        (Buffer        => About_Pixels,
         Buffer_Width  => About_Width,
         Buffer_Height => About_Height,
         X             => 16,
         Y             => 16,
         Rect_Width    => About_Width - 32,
         Rect_Height   => About_Height - 32,
         Color         => Pack_RGBA (0.04, 0.04, 0.08));
      Fill_Rect
        (Buffer        => About_Pixels,
         Buffer_Width  => About_Width,
         Buffer_Height => About_Height,
         X             => 20,
         Y             => 20,
         Rect_Width    => About_Width - 40,
         Rect_Height   => About_Height - 40,
         Color         => Pack_RGBA (0.08, 0.08, 0.14));

      Draw_Text
        (Buffer        => About_Pixels,
         Buffer_Width  => About_Width,
         Buffer_Height => About_Height,
         Text          => About_Title_Text,
         X             => Title_X,
         Y             => Title_Y,
         Scale         => Title_Scale,
         Color         => Title_Color,
         Visible_Chars => Title_Chars,
         Time_Sec      => Time_Sec,
         Wave_Amplitude => 8.0,
         Wave_Speed     => 4.8,
         Wave_Phase     => 0.55);

      if Elapsed > 1_000 then
         Draw_Text
           (Buffer        => About_Pixels,
            Buffer_Width  => About_Width,
            Buffer_Height => About_Height,
            Text          => About_Author_Text,
            X             => Author_X,
            Y             => 142,
            Scale         => Author_Scale,
            Color         => Author_Color,
            Time_Sec      => Time_Sec,
            Wave_Amplitude => 3.0,
            Wave_Speed     => 3.4,
            Wave_Phase     => 0.45);
      end if;

      if
        C_Bridge.Present_About_RGBA
          (Pixels => About_Pixels (About_Pixels'First)'Address,
           Pitch  => Interfaces.C.int (About_Width * 4))
        /= 0
      then
         Fail ("rendering about window failed: " & Bridge_Error);
      end if;
   end Render_About_Window;

   procedure Seed_Random_Generators is
      Year    : Ada.Calendar.Year_Number;
      Month   : Ada.Calendar.Month_Number;
      Day     : Ada.Calendar.Day_Number;
      Seconds : Ada.Calendar.Day_Duration;
      Seed    : Integer;
   begin
      Ada.Calendar.Split (Ada.Calendar.Clock, Year, Month, Day, Seconds);
      Seed :=
        Integer (Year) * 1_000_000
        + Integer (Month) * 10_000
        + Integer (Day) * 100
        + Integer (Seconds * 10.0);
      Random_Plasma_Modes.Reset (Mode_Generator, Seed);
      Random_Color_Modes.Reset (Color_Generator, Seed + 97);
   end Seed_Random_Generators;

   function Random_Mode_Different (Current : Plasma_Mode) return Plasma_Mode is
      Candidate : Plasma_Mode;
   begin
      loop
         Candidate := Random_Plasma_Modes.Random (Mode_Generator);
         exit when Candidate /= Current;
      end loop;

      return Candidate;
   end Random_Mode_Different;

   function Random_Colors_Different (Current : Color_Mode) return Color_Mode is
      Candidate : Color_Mode;
   begin
      loop
         Candidate := Random_Color_Modes.Random (Color_Generator);
         exit when Candidate /= Current;
      end loop;

      return Candidate;
   end Random_Colors_Different;

   procedure Randomize_Initial_Visuals is
   begin
      Current_Mode := Random_Plasma_Modes.Random (Mode_Generator);
      Current_Colors := Random_Color_Modes.Random (Color_Generator);
   end Randomize_Initial_Visuals;

   procedure Parse_Arguments is
      Index : Positive := 1;
      Song_Seen : Boolean := False;
   begin
      while Index <= Ada.Command_Line.Argument_Count loop
         declare
            Arg : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Arg = "--record" then
               if Index + 1 > Ada.Command_Line.Argument_Count then
                  Fail ("--record requires an output MP4 path");
               end if;

               Record_Mode_Enabled := True;
               Output_Path_Arg :=
                 To_Unbounded_String (Ada.Command_Line.Argument (Index + 1));
               Index := Index + 2;
            elsif Arg = "--auto-cooldown-ms" then
               if Index + 1 > Ada.Command_Line.Argument_Count then
                  Fail ("--auto-cooldown-ms requires a value");
               end if;

               declare
                  Value_Text : constant String :=
                    Ada.Command_Line.Argument (Index + 1);
               begin
                  begin
                     Auto_Switch_Cooldown_MS := Natural'Value (Value_Text);
                  exception
                     when Constraint_Error =>
                        Fail ("invalid --auto-cooldown-ms value: " & Value_Text);
                  end;

                  if Auto_Switch_Cooldown_MS = 0 then
                     Fail ("--auto-cooldown-ms must be greater than 0");
                  end if;
               end;

                Index := Index + 2;
            elsif Arg = "--window-size" then
               if Index + 1 > Ada.Command_Line.Argument_Count then
                  Fail ("--window-size requires a value");
               end if;

               Parse_Window_Size (Ada.Command_Line.Argument (Index + 1));
               Index := Index + 2;
            elsif Arg = "--intro-overlay" then
               Intro_Overlay_Enabled := True;
               Index := Index + 1;
            elsif Arg = "--name" then
               if Index + 1 > Ada.Command_Line.Argument_Count then
                  Fail ("--name requires a value");
               end if;

               Intro_Name_Arg :=
                 To_Unbounded_String (Ada.Command_Line.Argument (Index + 1));
               Index := Index + 2;
            elsif
              Arg'Length > 7
              and then Arg (Arg'First .. Arg'First + 6) = "--name="
            then
               if Arg'Length = 7 then
                  Fail ("--name requires a value");
               end if;

               Intro_Name_Arg :=
                 To_Unbounded_String (Arg (Arg'First + 7 .. Arg'Last));
               Index := Index + 1;
            elsif Arg'Length > 1 and then Arg (Arg'First .. Arg'First + 1) = "--" then
               Fail ("unknown option: " & Arg);
            else
               if Song_Seen then
                  Fail ("player accepts only one song path");
               end if;

               Input_Path_Arg := To_Unbounded_String (Arg);
               Song_Seen := True;
               Index := Index + 1;
            end if;
         end;
      end loop;

      if Record_Mode_Enabled and then Length (Output_Path_Arg) = 0 then
         Fail ("record mode requires an output MP4 path");
      end if;
   end Parse_Arguments;

   procedure Advance_Mode (Announce : Boolean := True) is
   begin
      case Current_Mode is
         when Classic =>
            Current_Mode := Rings;
         when Rings =>
            Current_Mode := Tunnel;
         when Tunnel =>
            Current_Mode := Spiral;
         when Spiral =>
            Current_Mode := Grid;
         when Grid =>
            Current_Mode := Wave;
         when Wave =>
            Current_Mode := Vortex;
         when Vortex =>
            Current_Mode := Ripple;
         when Ripple =>
            Current_Mode := Mosaic;
         when Mosaic =>
            Current_Mode := Helix;
         when Helix =>
            Current_Mode := Lattice;
         when Lattice =>
            Current_Mode := Pulse;
         when Pulse =>
            Current_Mode := Interference;
         when Interference =>
            Current_Mode := Metaball;
         when Metaball =>
            Current_Mode := Kaleidoscope;
         when Kaleidoscope =>
            Current_Mode := Warp;
         when Warp =>
            Current_Mode := Starburst;
         when Starburst =>
            Current_Mode := Aurora_Flow;
         when Aurora_Flow =>
            Current_Mode := Liquid_Marble;
         when Liquid_Marble =>
            Current_Mode := Hex_Field;
         when Hex_Field =>
            Current_Mode := Fractal_Pulse;
         when Fractal_Pulse =>
            Current_Mode := Lightning_Veins;
         when Lightning_Veins =>
            Current_Mode := Orbital_Wells;
         when Orbital_Wells =>
            Current_Mode := Classic;
      end case;

      if Announce then
         Ada.Text_IO.Put_Line ("Pattern: " & Mode_Name (Current_Mode));
      end if;

      Update_Window_Title;
   end Advance_Mode;

   procedure Advance_Colors (Announce : Boolean := True) is
   begin
      case Current_Colors is
         when Neon =>
            Current_Colors := Fire;
         when Fire =>
            Current_Colors := Ocean;
         when Ocean =>
            Current_Colors := Mono;
         when Mono =>
            Current_Colors := Aurora;
         when Aurora =>
            Current_Colors := Sunset;
         when Sunset =>
            Current_Colors := Ice;
         when Ice =>
            Current_Colors := Acid;
         when Acid =>
            Current_Colors := Ember;
         when Ember =>
            Current_Colors := Forest;
         when Forest =>
            Current_Colors := Candy;
         when Candy =>
            Current_Colors := Violet;
         when Violet =>
            Current_Colors := Gold;
         when Gold =>
            Current_Colors := Cyberpunk;
         when Cyberpunk =>
            Current_Colors := Toxic;
         when Toxic =>
            Current_Colors := Infrared;
         when Infrared =>
            Current_Colors := Deep_Space;
         when Deep_Space =>
            Current_Colors := Chrome;
         when Chrome =>
            Current_Colors := Nightclub;
         when Nightclub =>
            Current_Colors := Neon;
      end case;

      if Announce then
         Ada.Text_IO.Put_Line ("Colors: " & Color_Name (Current_Colors));
      end if;

      Update_Window_Title;
   end Advance_Colors;

   procedure Randomize_Visuals (Announce : Boolean := True) is
   begin
      Current_Mode := Random_Mode_Different (Current_Mode);
      Current_Colors := Random_Colors_Different (Current_Colors);

      if Announce then
         Ada.Text_IO.Put_Line
           ("Randomized -> Pattern: " & Mode_Name (Current_Mode)
            & ", Colors: " & Color_Name (Current_Colors));
      end if;

      Update_Window_Title;
   end Randomize_Visuals;

   procedure Toggle_Auto_Switching is
   begin
      Auto_Switching := not Auto_Switching;
      Ada.Text_IO.Put_Line ("Auto switch: " & Auto_State_Name (Auto_Switching));
   end Toggle_Auto_Switching;

   procedure Toggle_Color_Strobe (Now_MS : Natural) is
   begin
      Color_Strobe_Enabled := not Color_Strobe_Enabled;

      if Color_Strobe_Enabled then
         Advance_Colors (Announce => False);
         Last_Color_Strobe_MS := Now_MS;
      end if;

      Ada.Text_IO.Put_Line ("Color strobe: " & Auto_State_Name (Color_Strobe_Enabled));
   end Toggle_Color_Strobe;

   --  Each pattern is generated from a different combination of sine waves
   --  over normalized X/Y coordinates, polar coordinates, or coarse grid cells.
   --  Bass, mid, and treble levels modulate speed and shape so the same formula
   --  moves differently as the music changes.
   function Plasma_Value
     (Mode     : Plasma_Mode;
      X        : Float;
      Y        : Float;
      Time_Sec : Float) return Float
   is
      Dx       : constant Float := X - 0.5;
      Dy       : constant Float := Y - 0.5;
      Radius   : constant Float := Sqrt (Dx * Dx + Dy * Dy) + 0.000_1;
      Angle    : constant Float :=
        (if abs Dx < 0.000_1 and then abs Dy < 0.000_1 then 0.0
         else Arctan (Dy, Dx));
      Source_1_X : constant Float := 0.24 * Sin (Time_Sec * (1.6 + Bass_Level * 2.8));
      Source_1_Y : constant Float := 0.19 * Cos (Time_Sec * (1.2 + Mid_Level * 2.1));
      Source_2_X : constant Float := -0.22 * Cos (Time_Sec * (1.1 + Mid_Level * 2.4));
      Source_2_Y : constant Float := 0.21 * Sin (Time_Sec * (1.7 + Treble_Level * 2.7));
      Source_3_X : constant Float := 0.18 * Sin (Time_Sec * (2.1 + Treble_Level * 3.2));
      Source_3_Y : constant Float := -0.17 * Cos (Time_Sec * (1.5 + Bass_Level * 2.5));
      Distance_1 : constant Float :=
        Sqrt ((Dx - Source_1_X) * (Dx - Source_1_X) + (Dy - Source_1_Y) * (Dy - Source_1_Y))
        + 0.002;
      Distance_2 : constant Float :=
        Sqrt ((Dx - Source_2_X) * (Dx - Source_2_X) + (Dy - Source_2_Y) * (Dy - Source_2_Y))
        + 0.002;
      Distance_3 : constant Float :=
        Sqrt ((Dx - Source_3_X) * (Dx - Source_3_X) + (Dy - Source_3_Y) * (Dy - Source_3_Y))
        + 0.002;
      Warp_X     : constant Float :=
        X + 0.14 * Sin (Y * 10.0 + Time_Sec * (1.8 + Bass_Level * 4.8));
      Warp_Y     : constant Float :=
        Y + 0.14 * Cos (X * 12.0 - Time_Sec * (1.6 + Mid_Level * 4.3));
      Wdx        : constant Float := Warp_X - 0.5;
      Wdy        : constant Float := Warp_Y - 0.5;
      Warped_R   : constant Float := Sqrt (Wdx * Wdx + Wdy * Wdy) + 0.000_1;
      Warped_A   : constant Float :=
        (if abs Wdx < 0.000_1 and then abs Wdy < 0.000_1 then 0.0
         else Arctan (Wdy, Wdx));
    begin
      case Mode is
         when Classic =>
            return
              (Sin (X * 10.0 + Time_Sec * (1.1 + Bass_Level * 1.8))
               + Sin (Y * 13.0 - Time_Sec * (1.3 + Mid_Level * 1.4))
               + Sin ((X * 8.0 + Y * 7.0) + Time_Sec * (0.9 + Treble_Level * 1.2))
               + Sin
                   ((X * 22.0) * (Y * 12.0)
                    - Time_Sec * (0.7 + Bass_Level * 2.0)))
              / 4.0;

         when Rings =>
            return
              (Sin (Radius * 40.0 - Time_Sec * (4.0 + Bass_Level * 8.0))
               + Sin (Angle * 6.0 + Time_Sec * (2.0 + Mid_Level * 5.0))
               + Sin
                   ((Dx * 18.0 + Dy * 14.0)
                    + Time_Sec * (1.4 + Treble_Level * 6.0)))
              / 3.0;

         when Tunnel =>
            return
              (Sin ((1.0 / Radius) * 0.8 - Time_Sec * (3.5 + Bass_Level * 7.0))
               + Sin
                   ((Angle * 8.0) + (Radius * 24.0)
                     - Time_Sec * (2.3 + Mid_Level * 4.0))
               + Sin ((X - Y) * 20.0 + Time_Sec * (1.1 + Treble_Level * 5.0)))
              / 3.0;

         when Spiral =>
            return
              (Sin
                  (Angle * 12.0 + Radius * 36.0
                   - Time_Sec * (4.2 + Bass_Level * 7.5))
               + Sin
                   (Angle * 5.0 - Radius * 22.0
                    + Time_Sec * (2.1 + Mid_Level * 5.5))
               + Sin ((Dx + Dy) * 26.0 + Time_Sec * (1.7 + Treble_Level * 6.0)))
              / 3.0;

         when Grid =>
            return
              (Sin (X * 34.0 + Time_Sec * (2.2 + Bass_Level * 6.0))
               + Sin (Y * 28.0 - Time_Sec * (1.8 + Mid_Level * 5.0))
               + Sin
                   ((X + Y) * 20.0 + Time_Sec * (1.3 + Treble_Level * 5.5))
               + Sin
                   ((X - Y) * 24.0 - Time_Sec * (2.7 + Bass_Level * 4.5)))
              / 4.0;

         when Wave =>
            return
              (Sin
                  ((X * 16.0) + Sin (Y * 8.0 + Time_Sec * 1.8) * 5.0
                   + Time_Sec * (2.0 + Bass_Level * 6.5))
               + Sin
                   ((Y * 18.0) + Sin (X * 7.0 - Time_Sec * 1.4) * 4.0
                    - Time_Sec * (1.6 + Mid_Level * 5.0))
               + Sin ((X + Y) * 14.0 + Time_Sec * (1.1 + Treble_Level * 5.5)))
              / 3.0;

         when Vortex =>
            return
              (Sin
                  (Angle * 16.0 - (1.0 / Radius) * 0.55
                   - Time_Sec * (4.5 + Bass_Level * 8.0))
               + Sin
                   (Radius * 30.0 + Angle * 6.0
                    + Time_Sec * (2.0 + Mid_Level * 5.5))
                + Sin ((Dx * Dy) * 160.0 - Time_Sec * (1.4 + Treble_Level * 6.0)))
              / 3.0;

         when Ripple =>
            return
              (Sin (Radius * 52.0 - Time_Sec * (5.4 + Bass_Level * 8.5))
               + Sin (Radius * 18.0 + Angle * 7.0 + Time_Sec * (2.2 + Mid_Level * 5.4))
               + Sin ((Dx - Dy) * 22.0 - Time_Sec * (1.5 + Treble_Level * 6.2)))
              / 3.0;

         when Mosaic =>
            return
              (Sin (Float'Floor (X * 18.0) * 0.85 + Time_Sec * (1.8 + Bass_Level * 5.8))
               + Sin (Float'Floor (Y * 14.0) * 1.05 - Time_Sec * (1.7 + Mid_Level * 4.7))
               + Sin
                   (Float'Floor ((X + Y) * 12.0) * 0.95
                    + Time_Sec * (1.2 + Treble_Level * 5.9)))
              / 3.0;

         when Helix =>
            return
              (Sin (Angle * 10.0 + Radius * 28.0 + Time_Sec * (2.0 + Bass_Level * 6.8))
               + Sin (Angle * 14.0 - Radius * 20.0 - Time_Sec * (3.1 + Mid_Level * 5.7))
               + Sin ((X * 10.0 - Y * 16.0) + Time_Sec * (1.3 + Treble_Level * 5.8)))
              / 3.0;

         when Lattice =>
            return
              (Sin ((X * 26.0) * (Y * 18.0) + Time_Sec * (1.6 + Bass_Level * 5.8))
               + Sin ((X * 30.0) - (Y * 24.0) - Time_Sec * (2.4 + Mid_Level * 5.4))
               + Sin ((X * 24.0) + (Y * 24.0) + Time_Sec * (1.2 + Treble_Level * 5.0)))
              / 3.0;

         when Pulse =>
            return
              (Sin (Radius * 34.0 - Time_Sec * (6.2 + Bass_Level * 10.0))
               + Sin ((X + Y) * 18.0 + Time_Sec * (2.6 + Mid_Level * 5.5))
               + Sin ((X - Y) * 28.0 - Time_Sec * (2.0 + Treble_Level * 6.4))
               + Sin (Angle * 9.0 + Time_Sec * (1.1 + Bass_Level * 4.0)))
              / 4.0;

         when Interference =>
            return
              (Sin (Distance_1 * 58.0 - Time_Sec * (6.0 + Bass_Level * 8.0))
               + Sin (Distance_2 * 54.0 - Time_Sec * (5.3 + Mid_Level * 7.0))
               + Sin (Distance_3 * 60.0 - Time_Sec * (6.7 + Treble_Level * 7.8)))
              / 3.0;

         when Metaball =>
            declare
               Field : constant Float :=
                 0.11 / Distance_1 + 0.10 / Distance_2 + 0.09 / Distance_3;
            begin
               return
                 (Sin (Field * 18.0 - Time_Sec * (2.1 + Bass_Level * 4.2))
                  + Sin ((Field * 9.0) + Angle * 4.0 + Time_Sec * (1.6 + Mid_Level * 3.6))
                  + Sin ((X + Y) * 15.0 - Time_Sec * (1.2 + Treble_Level * 4.4)))
                 / 3.0;
            end;

         when Kaleidoscope =>
            return
              (Sin (abs (Sin (Angle * 6.0)) * 34.0 + Radius * 28.0
                    - Time_Sec * (4.4 + Bass_Level * 6.5))
               + Sin (abs (Cos (Angle * 8.0)) * 26.0 - Radius * 18.0
                    + Time_Sec * (2.2 + Mid_Level * 5.0))
               + Sin (abs (Sin ((X - Y) * 9.0)) * 16.0
                    + Time_Sec * (1.5 + Treble_Level * 5.2)))
              / 3.0;

         when Warp =>
            return
              (Sin (Warp_X * 26.0 + Time_Sec * (2.6 + Bass_Level * 6.2))
               + Sin (Warp_Y * 24.0 - Time_Sec * (2.0 + Mid_Level * 5.4))
               + Sin ((Warp_X + Warp_Y) * 18.0 + Time_Sec * (1.5 + Treble_Level * 5.6))
               + Sin (Warped_R * 20.0 + Warped_A * 7.0
                    - Time_Sec * (2.7 + Bass_Level * 4.4)))
              / 4.0;

         when Starburst =>
            return
              (Sin (Angle * 20.0 + Time_Sec * (2.4 + Treble_Level * 6.8))
               + Sin (Angle * 11.0 - Radius * 30.0 - Time_Sec * (4.9 + Bass_Level * 7.8))
               + Sin (Radius * 42.0 - Time_Sec * (5.6 + Bass_Level * 9.0))
               + Sin (abs (Sin (Angle * 14.0)) * 18.0 + Time_Sec * (1.3 + Mid_Level * 4.7)))
              / 4.0;

         when Aurora_Flow =>
            return
              (Sin
                  (Y * 20.0
                   + Sin (X * 6.0 + Time_Sec * (1.4 + Bass_Level * 3.8)) * 5.6
                   + Time_Sec * (1.1 + Mid_Level * 4.2))
               + Sin
                   (Y * 11.0 - X * 4.5
                    - Time_Sec * (1.6 + Treble_Level * 4.8))
               + Sin
                   ((Warp_Y - 0.5) * 26.0 + (Warp_X - 0.5) * 10.0
                    + Time_Sec * (1.3 + Bass_Level * 4.0)))
              / 3.0;

         when Liquid_Marble =>
            declare
               Field : constant Float :=
                 Sin (Distance_1 * 26.0 - Time_Sec * (2.0 + Bass_Level * 4.4))
                 + Sin (Distance_2 * 24.0 + Time_Sec * (1.6 + Mid_Level * 3.8))
                 + Sin (Distance_3 * 28.0 - Time_Sec * (2.3 + Treble_Level * 4.6));
            begin
               return
                 (Sin ((X + Field * 0.030) * 20.0 + Time_Sec * (1.7 + Bass_Level * 4.8))
                  + Sin ((Y - Field * 0.028) * 19.0 - Time_Sec * (1.5 + Mid_Level * 4.0))
                  + Sin
                      ((X - Y + Field * 0.020) * 17.0
                       + Time_Sec * (1.2 + Treble_Level * 4.8)))
                 / 3.0;
            end;

         when Hex_Field =>
            return
              (Sin
                  (Float'Floor (X * 20.0 + Y * 11.0) * 0.85
                   + Time_Sec * (1.8 + Bass_Level * 5.6))
               + Sin
                   (Float'Floor (Y * 22.0 - X * 11.0) * 0.82
                    - Time_Sec * (1.6 + Mid_Level * 5.0))
               + Sin
                   (Float'Floor ((X - Y) * 20.0) * 0.78
                    + Time_Sec * (1.2 + Treble_Level * 5.4)))
              / 3.0;

         when Fractal_Pulse =>
            return
              (Sin (Radius * 28.0 - Time_Sec * (5.0 + Bass_Level * 8.4))
               + 0.70 * Sin (Radius * 54.0 + Time_Sec * (2.6 + Mid_Level * 5.2))
               + 0.42 * Sin (Radius * 108.0 - Time_Sec * (1.4 + Treble_Level * 5.8))
               + 0.58 * Sin (Angle * 8.0 + Time_Sec * (1.3 + Bass_Level * 4.0)))
              / 2.70;

         when Lightning_Veins =>
            declare
               Vein_1 : constant Float :=
                 1.0 - abs (Sin ((X * 18.0 + Y * 12.0) + Time_Sec * (2.8 + Treble_Level * 6.6)));
               Vein_2 : constant Float :=
                 1.0 - abs (Sin ((X * 26.0 - Y * 22.0) - Time_Sec * (3.4 + Bass_Level * 7.4)));
               Vein_3 : constant Float :=
                 1.0 - abs (Sin (Angle * 9.0 + Radius * 18.0 - Time_Sec * (2.2 + Mid_Level * 5.2)));
            begin
               return ((Vein_1 * 2.0 - 1.0) + (Vein_2 * 2.0 - 1.0) + (Vein_3 * 2.0 - 1.0)) / 3.0;
            end;

         when Orbital_Wells =>
            return
              (Sin ((1.0 / Distance_1) * 0.28 + Angle * 4.0 - Time_Sec * (3.0 + Bass_Level * 5.4))
               + Sin ((1.0 / Distance_2) * 0.24 - Angle * 5.0 + Time_Sec * (2.2 + Mid_Level * 4.6))
               + Sin
                   ((1.0 / Distance_3) * 0.20 + Radius * 26.0
                    - Time_Sec * (2.8 + Treble_Level * 5.4)))
              / 3.0;
      end case;
   end Plasma_Value;

   procedure Apply_Colors
     (Mode       : Color_Mode;
      Norm       : Float;
      Bass_Pulse : Float;
      Mid_Pulse  : Float;
      Treble_Pulse : Float;
      Red        : out Float;
      Green      : out Float;
      Blue       : out Float)
   is
   begin
      case Mode is
         when Neon =>
            Red := Clamp_01 (Norm * (0.45 + Treble_Pulse) + Bass_Level * 0.2);
            Green :=
              Clamp_01
                ((0.25 + Norm * 0.75) * (0.55 + Mid_Pulse * 0.6));
            Blue :=
              Clamp_01
                ((1.0 - Norm * 0.65) * (0.70 + Bass_Pulse * 0.5));

         when Fire =>
            Red := Clamp_01 (0.35 + Norm * 0.85 + Bass_Level * 0.45);
            Green := Clamp_01 (Norm * 0.55 + Mid_Level * 0.35);
            Blue := Clamp_01 ((1.0 - Norm) * 0.18 + Treble_Level * 0.10);

         when Ocean =>
            Red := Clamp_01 ((1.0 - Norm) * 0.18 + Treble_Level * 0.12);
            Green := Clamp_01 (0.25 + Norm * 0.55 + Mid_Level * 0.30);
            Blue := Clamp_01 (0.45 + Norm * 0.70 + Bass_Level * 0.30);

         when Mono =>
            Red := Clamp_01 (0.20 + Norm * 0.80 + Bass_Level * 0.12);
            Green := Red;
            Blue := Clamp_01 (Red * (0.92 + Treble_Level * 0.08));

         when Aurora =>
            Red := Clamp_01 (0.12 + Norm * 0.35 + Treble_Level * 0.18);
            Green := Clamp_01 (0.30 + Norm * 0.60 + Mid_Level * 0.32);
            Blue := Clamp_01 (0.38 + (1.0 - Norm * 0.35) + Bass_Level * 0.22);

         when Sunset =>
            Red := Clamp_01 (0.42 + Norm * 0.58 + Bass_Level * 0.25);
            Green := Clamp_01 (0.12 + Norm * 0.42 + Mid_Level * 0.20);
            Blue := Clamp_01 (0.20 + (1.0 - Norm) * 0.45 + Treble_Level * 0.18);

         when Ice =>
            Red := Clamp_01 (0.12 + (1.0 - Norm) * 0.20 + Treble_Level * 0.08);
            Green := Clamp_01 (0.38 + Norm * 0.46 + Mid_Level * 0.18);
            Blue := Clamp_01 (0.62 + Norm * 0.36 + Bass_Level * 0.16);

         when Acid =>
            Red := Clamp_01 (0.26 + Norm * 0.58 + Bass_Level * 0.12);
            Green := Clamp_01 (0.60 + (1.0 - Norm) * 0.30 + Mid_Level * 0.20);
            Blue := Clamp_01 (0.10 + Treble_Level * 0.22 + (1.0 - Norm) * 0.12);

         when Ember =>
            Red := Clamp_01 (0.48 + Norm * 0.42 + Bass_Level * 0.20);
            Green := Clamp_01 (0.10 + Norm * 0.28 + Mid_Level * 0.14);
            Blue := Clamp_01 (0.04 + (1.0 - Norm) * 0.10 + Treble_Level * 0.06);

         when Forest =>
            Red := Clamp_01 (0.08 + (1.0 - Norm) * 0.12 + Treble_Level * 0.05);
            Green := Clamp_01 (0.24 + Norm * 0.58 + Mid_Level * 0.24);
            Blue := Clamp_01 (0.10 + Norm * 0.18 + Bass_Level * 0.08);

         when Candy =>
            Red := Clamp_01 (0.48 + Norm * 0.42 + Bass_Level * 0.12);
            Green := Clamp_01 (0.16 + (1.0 - Norm) * 0.20 + Mid_Level * 0.10);
            Blue := Clamp_01 (0.46 + Norm * 0.40 + Treble_Level * 0.16);

         when Violet =>
            Red := Clamp_01 (0.26 + Norm * 0.30 + Bass_Level * 0.08);
            Green := Clamp_01 (0.08 + Norm * 0.18 + Mid_Level * 0.08);
            Blue := Clamp_01 (0.42 + Norm * 0.48 + Treble_Level * 0.18);

         when Gold =>
            Red := Clamp_01 (0.56 + Norm * 0.40 + Bass_Level * 0.14);
            Green := Clamp_01 (0.34 + Norm * 0.34 + Mid_Level * 0.12);
            Blue := Clamp_01 (0.06 + (1.0 - Norm) * 0.12 + Treble_Level * 0.04);

         when Cyberpunk =>
            Red := Clamp_01 (0.48 + Norm * 0.34 + Treble_Pulse * 0.20);
            Green := Clamp_01 (0.10 + (1.0 - Norm) * 0.18 + Mid_Pulse * 0.08);
            Blue := Clamp_01 (0.56 + Norm * 0.36 + Bass_Pulse * 0.18);

         when Toxic =>
            Red := Clamp_01 (0.22 + Norm * 0.34 + Bass_Level * 0.10);
            Green := Clamp_01 (0.72 + (1.0 - Norm) * 0.22 + Mid_Level * 0.16);
            Blue := Clamp_01 (0.04 + Treble_Level * 0.08 + (1.0 - Norm) * 0.04);

         when Infrared =>
            Red := Clamp_01 (0.48 + Norm * 0.50 + Bass_Level * 0.18);
            Green := Clamp_01 (0.10 + Norm * 0.40 + Mid_Level * 0.16);
            Blue := Clamp_01 ((1.0 - Norm) * 0.10 + Treble_Level * 0.04);

         when Deep_Space =>
            Red := Clamp_01 (0.08 + Norm * 0.16 + Treble_Level * 0.08);
            Green := Clamp_01 (0.10 + Norm * 0.26 + Mid_Level * 0.12);
            Blue := Clamp_01 (0.32 + Norm * 0.52 + Bass_Level * 0.18);

         when Chrome =>
            Red := Clamp_01 (0.36 + Norm * 0.50 + Bass_Pulse * 0.10);
            Green := Clamp_01 (0.38 + Norm * 0.46 + Mid_Pulse * 0.08);
            Blue := Clamp_01 (0.42 + Norm * 0.40 + Treble_Pulse * 0.12);

         when Nightclub =>
            Red := Clamp_01 (0.34 + Norm * 0.40 + Bass_Level * 0.12);
            Green := Clamp_01 (0.08 + (1.0 - Norm) * 0.12 + Treble_Level * 0.10);
            Blue := Clamp_01 (0.42 + Norm * 0.36 + Mid_Level * 0.16);
      end case;
   end Apply_Colors;

   function Bar_Color_For
     (Bar             : Natural;
      Height_Fraction : Float;
      Bar_Level       : Float) return Interfaces.Unsigned_32
   is
      Position      : constant Float := Float (Bar) / Float (Spectrum_Bars);
      Height_Norm   : constant Float := Clamp_01 (Height_Fraction);
      Level_Norm    : constant Float := Clamp_01 (Bar_Level);
      Left_Weight   : constant Float := 1.0 - Position;
      Right_Weight  : constant Float := Position;
      Center_Weight : constant Float := 1.0 - abs (Position * 2.0 - 1.0);
      Tip_Glow      : constant Float := Height_Norm * Height_Norm;
      Body_Glow     : constant Float :=
        0.34 + Height_Norm * (0.66 + Level_Norm * 0.22);
      Highlight     : constant Float := Tip_Glow * (0.14 + Level_Norm * 0.24);
      Red           : Float;
      Green         : Float;
      Blue          : Float;
   begin
      case Current_Colors is
         when Neon =>
            Red := 0.4 + Position * 0.6;
            Green := 0.5 + Mid_Level * 0.5;
            Blue := 0.8 + Treble_Level * 0.2;

         when Fire =>
            Red := 0.75 + Position * 0.25;
            Green := 0.25 + Position * 0.45 + Mid_Level * 0.25;
            Blue := 0.05 + Treble_Level * 0.10;

         when Ocean =>
            Red := 0.08 + Treble_Level * 0.12;
            Green := 0.35 + Position * 0.40 + Mid_Level * 0.20;
            Blue := 0.65 + Position * 0.30 + Bass_Level * 0.18;

         when Mono =>
            Red := 0.35 + Position * 0.45;
            Green := Red;
            Blue := Red;

         when Aurora =>
            Red := 0.18 + Treble_Level * 0.16;
            Green := 0.55 + Position * 0.22 + Mid_Level * 0.18;
            Blue := 0.62 + Position * 0.22 + Bass_Level * 0.14;

         when Sunset =>
            Red := 0.72 + Position * 0.25;
            Green := 0.24 + Position * 0.30 + Mid_Level * 0.18;
            Blue := 0.28 + Treble_Level * 0.16;

         when Ice =>
            Red := 0.16 + Treble_Level * 0.10;
            Green := 0.56 + Position * 0.20 + Mid_Level * 0.12;
            Blue := 0.78 + Position * 0.18 + Bass_Level * 0.10;

         when Acid =>
            Red := 0.42 + Position * 0.26;
            Green := 0.72 + Mid_Level * 0.18;
            Blue := 0.12 + Treble_Level * 0.18;

         when Ember =>
            Red := 0.72 + Position * 0.20;
            Green := 0.18 + Position * 0.14 + Mid_Level * 0.08;
            Blue := 0.04 + Treble_Level * 0.04;

         when Forest =>
            Red := 0.08 + Treble_Level * 0.04;
            Green := 0.40 + Position * 0.24 + Mid_Level * 0.14;
            Blue := 0.10 + Bass_Level * 0.08;

         when Candy =>
            Red := 0.72 + Position * 0.16;
            Green := 0.18 + Mid_Level * 0.08;
            Blue := 0.58 + Position * 0.18 + Treble_Level * 0.10;

         when Violet =>
            Red := 0.28 + Position * 0.12;
            Green := 0.10 + Mid_Level * 0.06;
            Blue := 0.64 + Position * 0.18 + Treble_Level * 0.12;

         when Gold =>
            Red := 0.78 + Position * 0.18;
            Green := 0.52 + Position * 0.14 + Mid_Level * 0.08;
            Blue := 0.08 + Treble_Level * 0.04;

         when Cyberpunk =>
            Red := 0.68 + Position * 0.16;
            Green := 0.10 + Mid_Level * 0.06;
            Blue := 0.76 + Position * 0.14 + Treble_Level * 0.08;

         when Toxic =>
            Red := 0.26 + Position * 0.12;
            Green := 0.76 + Position * 0.14 + Mid_Level * 0.10;
            Blue := 0.04 + Treble_Level * 0.04;

         when Infrared =>
            Red := 0.78 + Position * 0.18;
            Green := 0.18 + Position * 0.28 + Mid_Level * 0.10;
            Blue := 0.04 + Treble_Level * 0.03;

         when Deep_Space =>
            Red := 0.10 + Treble_Level * 0.06;
            Green := 0.16 + Position * 0.16 + Mid_Level * 0.08;
            Blue := 0.50 + Position * 0.24 + Bass_Level * 0.12;

         when Chrome =>
            Red := 0.58 + Position * 0.22;
            Green := 0.60 + Position * 0.18 + Mid_Level * 0.06;
            Blue := 0.66 + Position * 0.16 + Treble_Level * 0.08;

         when Nightclub =>
            Red := 0.52 + Position * 0.18;
            Green := 0.08 + Mid_Level * 0.06;
            Blue := 0.72 + Position * 0.16 + Treble_Level * 0.08;
      end case;

      Red :=
        Clamp_01
          ((Red * (0.88 + Left_Weight * 0.36 + Level_Norm * 0.08))
           * Body_Glow
           + Highlight * (0.82 + Left_Weight * 0.22));
      Green :=
        Clamp_01
          ((Green * (0.82 + Center_Weight * 0.28 + Level_Norm * 0.06))
           * Body_Glow
           + Highlight * (0.66 + Center_Weight * 0.18));
      Blue :=
        Clamp_01
          ((Blue * (0.86 + Right_Weight * 0.42 + Level_Norm * 0.10))
           * Body_Glow
           + Highlight * (0.90 + Right_Weight * 0.26));

      return Pack_RGBA (Red, Green, Blue);
   end Bar_Color_For;

   procedure Initialize_Lookups is
   begin
      for X in X_Pos.all'Range loop
         X_Pos.all (X) := Float (X) / Float (Window_Width);
      end loop;

      for Y in Y_Pos.all'Range loop
         Y_Pos.all (Y) := Float (Y) / Float (Window_Height);
      end loop;

      for I in Hann'Range loop
         Hann (I) :=
           0.5
           * (1.0 - Cos
                (2.0 * Ada.Numerics.Pi * Float (I) / Float (Analysis_Size - 1)));
      end loop;
   end Initialize_Lookups;

   procedure Restart_Track;

   procedure Push_Chunk_To_History (Bytes_Read : Natural) is
      Frames_Read : constant Natural := Bytes_Read / Bytes_Per_Frame;
      Left        : Integer;
      Right       : Integer;
      Mono        : Float;
      Absolute    : Long_Long_Integer;
   begin
      for Frame in 0 .. Frames_Read - 1 loop
         Left := Integer (Chunk (Frame * 2));
         Right := Integer (Chunk (Frame * 2 + 1));
         Mono := Float (Left + Right) / 65_536.0;

         Absolute := Total_Frames_Enqueued + Long_Long_Integer (Frame);
         History (Natural (Absolute mod Long_Long_Integer (History_Size))) := Mono;
      end loop;

      Total_Frames_Enqueued := Total_Frames_Enqueued + Long_Long_Integer (Frames_Read);
   end Push_Chunk_To_History;

   procedure Refill_Audio is
      Bytes_Read : Interfaces.C.int;
   begin
      while Integer (C_Bridge.Get_Queued_Audio_Size) < Target_Queue loop
         Bytes_Read :=
           C_Bridge.Decode_Chunk
             (Buffer   => Chunk (Chunk'First)'Address,
              Capacity => Interfaces.C.int (Chunk_Bytes));

         if Bytes_Read < 0 then
            Fail ("decode failed: " & Bridge_Error);
         elsif Bytes_Read = 0 then
            C_Bridge.Rewind_MP3;
            Bytes_Read :=
              C_Bridge.Decode_Chunk
                (Buffer   => Chunk (Chunk'First)'Address,
                 Capacity => Interfaces.C.int (Chunk_Bytes));

            if Bytes_Read <= 0 then
               Fail ("restart after EOF failed: " & Bridge_Error);
            end if;
         end if;

         Push_Chunk_To_History (Natural (Bytes_Read));

         if
           C_Bridge.Queue_Audio
             (Buffer => Chunk (Chunk'First)'Address,
              Length => Interfaces.C.unsigned (Bytes_Read))
           /= 0
         then
            Fail ("audio queue failed: " & Bridge_Error);
         end if;
      end loop;
   end Refill_Audio;

   procedure Restart_Track is
   begin
      C_Bridge.Clear_Audio;
      C_Bridge.Rewind_MP3;
      History := (others => 0.0);
      Spectrum := (others => 0.0);
      Total_Frames_Enqueued := 0;
      Previous_Energy := 0.0;
      Energy_Flux := 0.0;
      Last_Auto_Switch_MS := 0;
      Last_Color_Strobe_MS := 0;
      Refill_Audio;
   end Restart_Track;

   procedure Reset_Visualization_State is
   begin
      -- Used by offline export so a render starts from a clean analyzer state
      -- without relying on the live playback loop.
      History := (others => 0.0);
      Spectrum := (others => 0.0);
      Total_Frames_Enqueued := 0;
      Previous_Energy := 0.0;
      Energy_Flux := 0.0;
      Last_Auto_Switch_MS := 0;
      Last_Color_Strobe_MS := 0;
      Bass_Level := 0.0;
      Mid_Level := 0.0;
      Treble_Level := 0.0;
   end Reset_Visualization_State;

   procedure Decode_Until (Target_Frame : Long_Long_Integer) is
      Bytes_Read : Interfaces.C.int;
   begin
      -- Offline rendering advances the decoder to an exact timeline position,
      -- then renders that video frame deterministically.
      while Total_Frames_Enqueued < Target_Frame loop
         Bytes_Read :=
           C_Bridge.Decode_Chunk
             (Buffer   => Chunk (Chunk'First)'Address,
              Capacity => Interfaces.C.int (Chunk_Bytes));

         if Bytes_Read < 0 then
            Fail ("decode failed: " & Bridge_Error);
         elsif Bytes_Read = 0 then
            exit;
         end if;

         Push_Chunk_To_History (Natural (Bytes_Read));
      end loop;
   end Decode_Until;

   procedure Fill_Window
     (Played_Frame : Long_Long_Integer;
      Window       : out Window_Buffer)
   is
      Oldest_Stored : Long_Long_Integer :=
        Total_Frames_Enqueued - Long_Long_Integer (History_Size);
      Sample_Index  : Long_Long_Integer;
   begin
      if Oldest_Stored < 0 then
         Oldest_Stored := 0;
      end if;

      for Offset in Window'Range loop
         Sample_Index :=
           Played_Frame - Long_Long_Integer (Analysis_Size - 1 - Offset);

         if Sample_Index < Oldest_Stored or else Sample_Index < 0 then
            Window (Offset) := 0.0;
         else
            Window (Offset) :=
              History
                (Natural (Sample_Index mod Long_Long_Integer (History_Size)));
         end if;
      end loop;
   end Fill_Window;

   function Goertzel (Window : Window_Buffer; Frequency : Float) return Float is
      Omega      : constant Float :=
        2.0 * Ada.Numerics.Pi * Frequency / Float (Sample_Rate);
      Coeff      : constant Float := 2.0 * Cos (Omega);
      Previous_1 : Float := 0.0;
      Previous_2 : Float := 0.0;
      Current    : Float;
   begin
      for I in Window'Range loop
         Current := Window (I) * Hann (I) + Coeff * Previous_1 - Previous_2;
         Previous_2 := Previous_1;
         Previous_1 := Current;
      end loop;

      return
        Previous_1 * Previous_1
        + Previous_2 * Previous_2
        - Coeff * Previous_1 * Previous_2;
   end Goertzel;

   function Bar_Frequency (Bar : Natural) return Float is
      Min_Freq : constant Float := 40.0;
      Max_Freq : constant Float := 12_000.0;
      Position : constant Float := Float (Bar) / Float (Spectrum_Bars - 1);
   begin
      return Min_Freq * Exp (Log (Max_Freq / Min_Freq) * Position);
   end Bar_Frequency;

   procedure Update_Spectrum (Played_Frame : Long_Long_Integer) is
      Window                : Window_Buffer;
      Magnitude             : Float;
      Bass_Sum              : Float := 0.0;
      Mid_Sum               : Float := 0.0;
      Treble_Sum            : Float := 0.0;
      Bass_Count            : Natural := 0;
      Mid_Count             : Natural := 0;
      Treble_Count          : Natural := 0;
   begin
      Fill_Window (Played_Frame, Window);

      for Bar in Spectrum'Range loop
         Magnitude :=
           Clamp_01 (Sqrt (Goertzel (Window, Bar_Frequency (Bar))) * 5.5);
         Spectrum (Bar) := Spectrum (Bar) * 0.78 + Magnitude * 0.22;

         if Bar <= 11 then
            Bass_Sum := Bass_Sum + Spectrum (Bar);
            Bass_Count := Bass_Count + 1;
         elsif Bar <= 31 then
            Mid_Sum := Mid_Sum + Spectrum (Bar);
            Mid_Count := Mid_Count + 1;
         else
            Treble_Sum := Treble_Sum + Spectrum (Bar);
            Treble_Count := Treble_Count + 1;
         end if;
      end loop;

      Bass_Level :=
        Bass_Level * 0.75 + (Bass_Sum / Float (Bass_Count)) * 0.25;
      Mid_Level :=
        Mid_Level * 0.75 + (Mid_Sum / Float (Mid_Count)) * 0.25;
      Treble_Level :=
        Treble_Level * 0.75 + (Treble_Sum / Float (Treble_Count)) * 0.25;
   end Update_Spectrum;

   procedure Try_Auto_Switch (Now_MS : Natural) is
      Energy     : constant Float :=
        Bass_Level * 1.45 + Mid_Level + Treble_Level * 0.85;
      Energy_Change : constant Float := abs (Energy - Previous_Energy);
      Threshold  : constant Float := 0.04 + Energy_Flux * 1.05;
      Can_Switch : constant Boolean :=
        Now_MS >= Last_Auto_Switch_MS + Auto_Switch_Cooldown_MS;
   begin
      -- Energy_Flux tracks how turbulent the recent audio has been so the
      -- switching threshold rises and falls with the song.
      Energy_Flux := Energy_Flux * 0.90 + Energy_Change * 0.10;

      -- A switch happens only when auto mode is on, the cooldown has expired,
      -- the current energy change beats the adaptive threshold, and the music
      -- is energetic enough overall to avoid random low-level flicker.
      if
        Auto_Switching
        and then Can_Switch
        and then Energy_Change > Threshold
        and then Energy > 0.16
      then
         Randomize_Visuals (Announce => False);
         Last_Auto_Switch_MS := Now_MS;
         Ada.Text_IO.Put_Line
            ("Auto switch -> Pattern: " & Mode_Name (Current_Mode)
            & ", Colors: " & Color_Name (Current_Colors));
      end if;

      Previous_Energy := Energy;
   end Try_Auto_Switch;

   procedure Try_Color_Strobe (Now_MS : Natural) is
   begin
      if
        Color_Strobe_Enabled
        and then Now_MS >= Last_Color_Strobe_MS + Color_Strobe_Interval_MS
      then
         Advance_Colors (Announce => False);
         Last_Color_Strobe_MS := Now_MS;
      end if;
   end Try_Color_Strobe;

   procedure Render_Frame (Time_Sec : Float) is
      use type Interfaces.Unsigned_32;

      Bass_Pulse   : constant Float := 0.4 + Bass_Level * 1.8;
      Mid_Pulse    : constant Float := 0.3 + Mid_Level * 1.4;
      Treble_Pulse : constant Float := 0.2 + Treble_Level * 1.2;
      Value        : Float;
      Norm         : Float;
      Red          : Float;
      Green        : Float;
      Blue         : Float;
      Index        : Natural;
      Bar_Width    : constant Natural := Natural'Max (1, Window_Width / Spectrum_Bars);
      Bar_Height   : Natural;
      X_Start      : Natural;
      X_End        : Natural;
      Bar_Color    : Interfaces.Unsigned_32;
      Bar_Level    : Float;
      Height_Frac  : Float;
    begin
      for Y in Y_Pos.all'Range loop
         for X in X_Pos.all'Range loop
            Value := Plasma_Value (Current_Mode, X_Pos.all (X), Y_Pos.all (Y), Time_Sec);

            Norm := 0.5 + 0.5 * Value;

            Apply_Colors
              (Mode         => Current_Colors,
               Norm         => Norm,
               Bass_Pulse   => Bass_Pulse,
               Mid_Pulse    => Mid_Pulse,
               Treble_Pulse => Treble_Pulse,
               Red          => Red,
               Green        => Green,
               Blue         => Blue);

            if Paused then
               Red := Red * 0.35;
               Green := Green * 0.35;
               Blue := Blue * 0.45;
            end if;

            Index := Y * Window_Width + X;
            Pixels.all (Index) := Pack_RGBA (Red, Green, Blue);
         end loop;
      end loop;

      if Show_Spectrum then
         for Bar in Spectrum'Range loop
            Bar_Level := Clamp_01 (Spectrum (Bar));
            Bar_Height :=
              Natural
                (Float (Window_Height) * (0.08 + Bar_Level * 0.55));
            X_Start := Bar * Bar_Width;
            X_End := Natural'Min (Window_Width - 1, X_Start + Bar_Width - 2);
 
            for Y in Window_Height - Bar_Height .. Window_Height - 1 loop
               if Bar_Height <= 1 then
                  Height_Frac := 1.0;
               else
                  Height_Frac :=
                    Float (Window_Height - 1 - Y) / Float (Bar_Height - 1);
               end if;

               Bar_Color := Bar_Color_For (Bar, Height_Frac, Bar_Level);

               for X in X_Start .. X_End loop
                  Pixels.all (Y * Window_Width + X) := Bar_Color;
               end loop;
            end loop;
         end loop;
      end if;
   end Render_Frame;

   function Shell_Quote (Text : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("'");
   begin
      for Ch of Text loop
         if Ch = ''' then
            Append (Result, "'""'""'");
         else
            Append (Result, String'(1 => Ch));
         end if;
      end loop;

      Append (Result, "'");
      return To_String (Result);
   end Shell_Quote;

   function Encoder_Command (Input_Path, Output_File : String) return String is
      function Image_Of (Value : Integer) return String is
      begin
         return Trim (Integer'Image (Value), Both);
      end Image_Of;
   begin
      return
        "ffmpeg -y -loglevel error -f rawvideo -pixel_format bgra -video_size "
        & Image_Of (Window_Width) & "x" & Image_Of (Window_Height)
        & " -framerate " & Image_Of (Export_FPS)
        & " -i - -i " & Shell_Quote (Input_Path)
        & " -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "
        & Shell_Quote (Output_File);
   end Encoder_Command;

   procedure Write_Frame_To_Pipe (Handle : System.Address) is
      Expected : constant Interfaces.C.size_t :=
        Interfaces.C.size_t (Window_Width * Window_Height * 4);
      Written  : constant Interfaces.C.size_t :=
        C_Bridge.Pipe_Write (Handle, Pixels.all (Pixels.all'First)'Address, Expected);
   begin
      if Written /= Expected then
         Fail ("writing video frame failed: " & Bridge_Error);
      end if;
   end Write_Frame_To_Pipe;

   procedure Render_To_MP4 (Input_Path, Output_File : String) is
      Pipe_Command  : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String (Encoder_Command (Input_Path, Output_File));
      Pipe_Handle   : System.Address;
      Track_Frames  : constant Long_Long_Integer :=
        Long_Long_Integer (C_Bridge.Track_Length_Frames);
      Frame_Count   : constant Long_Long_Integer :=
        (Track_Frames * Export_FPS + Sample_Rate - 1) / Sample_Rate;
      Played_Frame  : Long_Long_Integer;
      Now_MS        : Natural;
   begin
      if Track_Frames <= 0 then
         Fail ("could not determine track length");
      end if;

      -- ffmpeg reads raw BGRA frames from stdin while taking the MP3 as the
      -- audio source, so the export stays simple and fully offline.
      Pipe_Handle := C_Bridge.Pipe_Open_Write (Pipe_Command);
      Interfaces.C.Strings.Free (Pipe_Command);

      if Pipe_Handle = System.Null_Address then
         Fail ("opening ffmpeg pipe failed: " & Bridge_Error);
      end if;

      Reset_Visualization_State;
      Auto_Switching := True;

      Ada.Text_IO.Put_Line ("Recording MP4 to " & Output_File);
      Ada.Text_IO.Put_Line ("Pattern: " & Mode_Name (Current_Mode));
      Ada.Text_IO.Put_Line ("Colors: " & Color_Name (Current_Colors));
      Ada.Text_IO.Put_Line ("Auto switch: " & Auto_State_Name (Auto_Switching));
      if Intro_Overlay_Enabled then
         Ada.Text_IO.Put_Line ("Intro overlay: On");
      end if;

      for Video_Frame in 0 .. Frame_Count - 1 loop
         -- Map each video frame to a playback position, update analysis from
         -- decoded PCM, then render exactly one frame for the encoder.
         Played_Frame := (Video_Frame * Sample_Rate) / Export_FPS;
         Decode_Until (Played_Frame + 1);
         Update_Spectrum (Played_Frame);
         Now_MS := Natural ((Video_Frame * 1_000) / Export_FPS);
         Try_Auto_Switch (Now_MS);
         Render_Frame (Float (Video_Frame) / Float (Export_FPS));
         Render_Intro_Overlay (Now_MS, Float (Video_Frame) / Float (Export_FPS));
         Write_Frame_To_Pipe (Pipe_Handle);
      end loop;

      if C_Bridge.Pipe_Close (Pipe_Handle) /= 0 then
         Fail ("ffmpeg did not finish cleanly");
      end if;
   end Render_To_MP4;

   Title_Ptr : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.Null_Ptr;
   Path_Ptr  : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.Null_Ptr;
begin
   Parse_Arguments;
   Intro_Title_Arg :=
     To_Unbounded_String (Intro_Title_From_Path (To_String (Input_Path_Arg)));
   Initialize_Render_Buffers;
   Seed_Random_Generators;
   Randomize_Initial_Visuals;
   Initialize_Lookups;
   Title_Ptr := Interfaces.C.Strings.New_String ("Ada Plasma Player");
   Path_Ptr := Interfaces.C.Strings.New_String (To_String (Input_Path_Arg));

   if Record_Mode_Enabled then
      if C_Bridge.Prepare_Decoder /= 0 then
         Fail ("decoder init failed: " & Bridge_Error);
      end if;

      if C_Bridge.Open_MP3_Silent (Path_Ptr) /= 0 then
         Fail ("opening MP3 failed: " & Bridge_Error);
      end if;

      Interfaces.C.Strings.Free (Title_Ptr);
      Title_Ptr := Interfaces.C.Strings.Null_Ptr;
      Interfaces.C.Strings.Free (Path_Ptr);
      Path_Ptr := Interfaces.C.Strings.Null_Ptr;

      Intro_Overlay_Start_MS := 0;
      Render_To_MP4 (To_String (Input_Path_Arg), To_String (Output_Path_Arg));
   else
      if
        C_Bridge.Init
          (Title  => Title_Ptr,
           Width  => Interfaces.C.int (Window_Width),
           Height => Interfaces.C.int (Window_Height))
        /= 0
      then
         Fail ("SDL/mpg123 init failed: " & Bridge_Error);
      end if;

      if C_Bridge.Open_MP3 (Path_Ptr) /= 0 then
         Fail ("opening MP3 failed: " & Bridge_Error);
      end if;

      Interfaces.C.Strings.Free (Title_Ptr);
      Title_Ptr := Interfaces.C.Strings.Null_Ptr;
      Interfaces.C.Strings.Free (Path_Ptr);
      Path_Ptr := Interfaces.C.Strings.Null_Ptr;

      Ada.Text_IO.Put_Line
         ("Controls: Space pause/resume, A toggle bars, P next pattern, C next colors, S color strobe, M auto switch, R restart, Esc quit");
      Update_Window_Title;
      Ada.Text_IO.Put_Line ("Pattern: " & Mode_Name (Current_Mode));
      Ada.Text_IO.Put_Line ("Colors: " & Color_Name (Current_Colors));
      Ada.Text_IO.Put_Line ("Auto switch: " & Auto_State_Name (Auto_Switching));
      Ada.Text_IO.Put_Line ("Color strobe: " & Auto_State_Name (Color_Strobe_Enabled));
      if Intro_Overlay_Enabled then
         Ada.Text_IO.Put_Line ("Intro overlay: On");
      end if;

      Intro_Overlay_Start_MS := Natural (C_Bridge.Ticks);

      Refill_Audio;

      loop
         declare
            Events       : constant Interfaces.Unsigned_32 :=
              Interfaces.Unsigned_32 (Integer (C_Bridge.Poll_Event));
            Now_MS       : constant Natural := Natural (C_Bridge.Ticks);
            Queued_Bytes : constant Long_Long_Integer :=
              Long_Long_Integer (C_Bridge.Get_Queued_Audio_Size);
            Played_Frame : Long_Long_Integer :=
              Total_Frames_Enqueued - (Queued_Bytes / Bytes_Per_Frame);
         begin
            if
              (Events and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Quit))) /= 0
            then
               exit;
            end if;

            if
              (Events
               and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Toggle_Pause)))
              /= 0
            then
               Paused := not Paused;
               C_Bridge.Pause_Audio (Interfaces.C.int (Boolean'Pos (Paused)));
            end if;

            if
              (Events
               and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Toggle_Bars)))
             /= 0
            then
               Show_Spectrum := not Show_Spectrum;
            end if;

            if
              (Events
               and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Next_Pattern)))
              /= 0
            then
               Advance_Mode;
            end if;

            if
              (Events
               and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Next_Colors)))
              /= 0
            then
               Advance_Colors;
            end if;

            if
              (Events
               and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Toggle_Auto)))
              /= 0
            then
               Toggle_Auto_Switching;
            end if;

            if
              (Events
               and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Toggle_Strobe)))
              /= 0
            then
               Toggle_Color_Strobe (Now_MS);
            end if;

            if
              (Events
               and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Toggle_About)))
              /= 0
            then
               Toggle_About_Window (Now_MS);
            end if;

            if
              (Events
               and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Close_About)))
              /= 0
            then
               About_Visible := False;
            end if;

            if
                (Events and Interfaces.Unsigned_32 (Integer (C_Bridge.Event_Restart)))
               /= 0
            then
               Restart_Track;
            elsif not Paused then
               Refill_Audio;
            end if;

            if Played_Frame < 0 then
               Played_Frame := 0;
            end if;

            Update_Spectrum (Played_Frame);
            Try_Auto_Switch (Now_MS);
            Try_Color_Strobe (Now_MS);
            Render_Frame (Float (Now_MS) / 1_000.0);
            Render_Intro_Overlay (Now_MS, Float (Now_MS) / 1_000.0);

            if
              C_Bridge.Present_RGBA
                (Pixels => Pixels.all (Pixels.all'First)'Address,
                 Pitch  => Interfaces.C.int (Window_Width * 4))
              /= 0
            then
               Fail ("render failed: " & Bridge_Error);
            end if;

            if About_Visible then
               Render_About_Window (Now_MS);
            end if;
         end;

         C_Bridge.Delay_MS (Frame_Delay_MS);
      end loop;
   end if;

   Hide_About_Window;
   C_Bridge.Shutdown;
exception
   when others =>
      Hide_About_Window;
      Interfaces.C.Strings.Free (Title_Ptr);
      Interfaces.C.Strings.Free (Path_Ptr);
      C_Bridge.Shutdown;
      raise;
end Plasma_Player;
