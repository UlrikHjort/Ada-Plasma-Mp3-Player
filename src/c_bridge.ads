-- ***************************************************************************
--                   Plasma Player - C bridge
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
with Interfaces.C;
with Interfaces.C.Strings;
with System;

package C_Bridge is
   subtype C_Int is Interfaces.C.int;
   subtype C_Unsigned is Interfaces.C.unsigned;

   Event_Quit         : constant C_Int := 1;
   Event_Toggle_Pause : constant C_Int := 2;
   Event_Restart      : constant C_Int := 4;
   Event_Toggle_Bars  : constant C_Int := 8;
   Event_Next_Pattern : constant C_Int := 16;
   Event_Next_Colors  : constant C_Int := 32;
   Event_Toggle_Auto  : constant C_Int := 64;
   Event_Toggle_About : constant C_Int := 128;
   Event_Close_About  : constant C_Int := 256;
   Event_Toggle_Strobe : constant C_Int := 512;

   function Init
     (Title  : Interfaces.C.Strings.chars_ptr;
      Width  : C_Int;
      Height : C_Int) return C_Int
   with Import, Convention => C, External_Name => "player_bridge_init";

   function Prepare_Decoder return C_Int
   with Import, Convention => C, External_Name => "player_bridge_prepare_decoder";

   procedure Shutdown
   with Import, Convention => C, External_Name => "player_bridge_shutdown";

   function Open_MP3 (Path : Interfaces.C.Strings.chars_ptr) return C_Int
   with Import, Convention => C, External_Name => "player_bridge_open_mp3";

   function Open_MP3_Silent (Path : Interfaces.C.Strings.chars_ptr) return C_Int
   with Import, Convention => C, External_Name => "player_bridge_open_mp3_silent";

   function Decode_Chunk
     (Buffer   : System.Address;
      Capacity : C_Int) return C_Int
   with Import, Convention => C, External_Name => "player_bridge_decode_chunk";

   function Track_Length_Frames return Interfaces.C.long_long
   with Import, Convention => C, External_Name => "player_bridge_track_length_frames";

   function Queue_Audio
     (Buffer : System.Address;
      Length : C_Unsigned) return C_Int
   with Import, Convention => C, External_Name => "player_bridge_queue_audio";

   function Get_Queued_Audio_Size return C_Unsigned
   with Import, Convention => C, External_Name => "player_bridge_get_queued_audio_size";

   procedure Clear_Audio
   with Import, Convention => C, External_Name => "player_bridge_clear_audio";

   procedure Pause_Audio (Paused : C_Int)
   with Import, Convention => C, External_Name => "player_bridge_pause_audio";

   procedure Rewind_MP3
   with Import, Convention => C, External_Name => "player_bridge_rewind_mp3";

   function Poll_Event return C_Int
   with Import, Convention => C, External_Name => "player_bridge_poll_event";

   procedure Set_Window_Title (Title : Interfaces.C.Strings.chars_ptr)
   with Import, Convention => C, External_Name => "player_bridge_set_window_title";

   function Open_About_Window
     (Title  : Interfaces.C.Strings.chars_ptr;
      Width  : C_Int;
      Height : C_Int) return C_Int
   with Import, Convention => C, External_Name => "player_bridge_open_about_window";

   procedure Close_About_Window
   with Import, Convention => C, External_Name => "player_bridge_close_about_window";

   function Present_About_RGBA
     (Pixels : System.Address;
      Pitch  : C_Int) return C_Int
   with Import, Convention => C, External_Name => "player_bridge_present_about_rgba";

   function Present_RGBA
     (Pixels : System.Address;
      Pitch  : C_Int) return C_Int
   with Import, Convention => C, External_Name => "player_bridge_present_rgba";

   function Ticks return Interfaces.C.unsigned
   with Import, Convention => C, External_Name => "player_bridge_ticks";

   procedure Delay_MS (Milliseconds : Interfaces.C.unsigned)
   with Import, Convention => C, External_Name => "player_bridge_delay";

   function Pipe_Open_Write
     (Command : Interfaces.C.Strings.chars_ptr) return System.Address
   with Import, Convention => C, External_Name => "player_bridge_pipe_open_write";

   function Pipe_Write
     (Handle : System.Address;
      Buffer : System.Address;
      Length : Interfaces.C.size_t) return Interfaces.C.size_t
   with Import, Convention => C, External_Name => "player_bridge_pipe_write";

   function Pipe_Close (Handle : System.Address) return C_Int
   with Import, Convention => C, External_Name => "player_bridge_pipe_close";

   function Last_Error return Interfaces.C.Strings.chars_ptr
   with Import, Convention => C, External_Name => "player_bridge_last_error";
end C_Bridge;
