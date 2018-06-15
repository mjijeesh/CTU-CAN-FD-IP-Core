--------------------------------------------------------------------------------
--
-- CTU CAN FD IP Core
-- Copyright (C) 2015-2018 Ondrej Ille <ondrej.ille@gmail.com>
--
-- Project advisors and co-authors:
-- 	Jiri Novak <jnovak@fel.cvut.cz>
-- 	Pavel Pisa <pisa@cmp.felk.cvut.cz>
-- 	Martin Jerabek <jerabma7@fel.cvut.cz>
-- Department of Measurement         (http://meas.fel.cvut.cz/)
-- Faculty of Electrical Engineering (http://www.fel.cvut.cz)
-- Czech Technical University        (http://www.cvut.cz/)
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this VHDL component and associated documentation files (the "Component"),
-- to deal in the Component without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense,
-- and/or sell copies of the Component, and to permit persons to whom the
-- Component is furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Component.
--
-- THE COMPONENT IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHTHOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE COMPONENT OR THE USE OR OTHER DEALINGS
-- IN THE COMPONENT.
--
-- The CAN protocol is developed by Robert Bosch GmbH and protected by patents.
-- Anybody who wants to implement this IP core on silicon has to obtain a CAN
-- protocol license from Bosch.
--
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Purpose:
--  Feature test for immediate abortion of CAN Transmission.
--
--  Test sequence:
--      1. Generate CAN Frame, and start transmission by Node 1.
--      2. Wait until transmission is started, plus some random time.
--      3. Read protocol control state, and if unit is still in the frame,
--         send "abort" command via COMMAND register.
--      4. Wait 5 clock cycles and check if unit stopped being transmitter!
--      5. Wait until the other unit transmitts error frame which is caused
--         by sudden disapearing of transmitter during frame.
--      6. Clear error counters.
--
--------------------------------------------------------------------------------
-- Revision History:
--     22.6.2016  Created file
--    06.02.2018  Modified to work with the IP-XACT generated memory map
--     12.6.2018  Modified test to use HAL like functions from CAN Test lib
--                instead of raw register access functions.
--------------------------------------------------------------------------------

Library ieee;
USE IEEE.std_logic_1164.all;
USE IEEE.numeric_std.ALL;
USE ieee.math_real.ALL;
use work.CANconstants.all;
USE work.CANtestLib.All;
USE work.randomLib.All;

use work.CAN_FD_register_map.all;

package abort_transmittion_feature is

    procedure abort_transmittion_feature_exec(
        variable    outcome         : inout  boolean;
        signal      rand_ctr        : inout  natural range 0 to RAND_POOL_SIZE;
        signal      mem_bus_1       : inout  Avalon_mem_type;
        signal      mem_bus_2       : inout  Avalon_mem_type;
        signal      bus_level       : in     std_logic;
        signal      drv_bus_1       : in     std_logic_vector(1023 downto 0);
        signal      drv_bus_2       : in     std_logic_vector(1023 downto 0);
        signal      stat_bus_1      : in     std_logic_vector(511 downto 0);
        signal      stat_bus_2      : in     std_logic_vector(511 downto 0)
    );

end package;


package body abort_transmittion_feature is

    procedure abort_transmittion_feature_exec(
        variable    outcome         : inout  boolean;
        signal      rand_ctr        : inout  natural range 0 to RAND_POOL_SIZE;
        signal      mem_bus_1       : inout  Avalon_mem_type;
        signal      mem_bus_2       : inout  Avalon_mem_type;
        signal      bus_level       : in     std_logic;
        signal      drv_bus_1       : in     std_logic_vector(1023 downto 0);
        signal      drv_bus_2       : in     std_logic_vector(1023 downto 0);
        signal      stat_bus_1      : in     std_logic_vector(511 downto 0);
        signal      stat_bus_2      : in     std_logic_vector(511 downto 0)
    )is
        variable r_data             :       std_logic_vector(31 downto 0) :=
                                                (OTHERS => '0');
        variable w_data             :       std_logic_vector(31 downto 0) :=
                                                (OTHERS => '0');
        variable ID_1           	:       natural := 1;
        variable ID_2           	:       natural := 2;
        variable CAN_frame          :       SW_CAN_frame_type;
        variable frame_sent         :       boolean := false;
        variable frame_length       :       natural;
        variable rand_value         :       real;
        variable wt                 :       time;
        variable bus_config         :       bit_time_config_type;
        variable still_tx           :       boolean := false;
        variable PC_State           :       protocol_type;
        variable err_counters       :       SW_error_counters;
        variable command            :       SW_command := (false, false, false);
        variable status             :       SW_status;
  begin
        outcome := true;

        ------------------------------------------------------------------------
        -- Generate CAN frame
        ------------------------------------------------------------------------
        CAN_generate_frame(rand_ctr, CAN_frame);

        ------------------------------------------------------------------------
        -- Insert the frame for transmittion
        ------------------------------------------------------------------------
        CAN_send_frame(CAN_frame, 1, ID_1, mem_bus_1, frame_sent);

        ------------------------------------------------------------------------
        -- Wait until unit turns transmitter
        ------------------------------------------------------------------------
        loop
            get_controller_status(status, ID_1, mem_bus_1);
            if (status.transmitter) then
                exit;
            end if;
        end loop;

        ------------------------------------------------------------------------
        -- Now wait random time up to 25 000 clock cycles!
        -- But at least 200 clock cycles! We want to avoid situation that unit
        -- aborts immediately after the frame was commited and SOF was not
        -- yet sent!
        ------------------------------------------------------------------------
        wait_rand_cycles(rand_ctr, mem_bus_1.clk_sys, 200, 25000);

        ------------------------------------------------------------------------
        -- Check that unit is not transciever anymore, unit should be now as if
        -- bus was idle... But unit is still transciever even in interframe
        -- space. So we check the PC_State from status bus explicitly.
        ------------------------------------------------------------------------
        PC_State := protocol_type'VAL(to_integer(unsigned(
                     stat_bus_1(STAT_PC_STATE_HIGH downto STAT_PC_STATE_LOW))));

        report "PC State: " & protocol_type'Image(PC_State);
        if (PC_State = sof or PC_State = arbitration or PC_State = control or
            PC_State = data or PC_State = crc)
        then
            still_tx := true;
        else
            still_tx := false;
        end if;
        report "Wait end";

        if still_tx then

            --------------------------------------------------------------------
            -- Now send the command to abort the transmittion
            --------------------------------------------------------------------
            command.abort_transmission := true;
            give_controller_command(command, ID_1, mem_bus_1);

            --------------------------------------------------------------------
            -- Now wait for few clock cycles until Node aborts the transmittion
            --------------------------------------------------------------------
            for i in 0 to 5 loop
                wait until rising_edge(mem_bus_1.clk_sys);
            end loop;

            get_controller_status(status, ID_1, mem_bus_1);
            if (status.transmitter) then
                outcome := false;
            end if;

            --------------------------------------------------------------------
            -- Now wait until unit 2 starts transmitting error frame! Note that
            -- we cant wait until unit 1 starts to transmitt error frame! This
            -- works only when both units are error active! When unit 2 turns
            -- error passive unit 1 never starts transmitting active error
            -- frame. It stays idle since it recieves recessive error passive
            -- error frame from 2!
            --------------------------------------------------------------------
            CAN_wait_error_transmitted(ID_2, mem_bus_2);

            --------------------------------------------------------------------
            -- Now wait until bus is idle in both units
            --------------------------------------------------------------------
            CAN_wait_bus_idle(ID_2, mem_bus_2);
            CAN_wait_bus_idle(ID_1, mem_bus_1);

        else

            --------------------------------------------------------------------
            -- Now wait until bus is idle in both units
            --------------------------------------------------------------------
            CAN_wait_bus_idle(ID_2, mem_bus_2);
            CAN_wait_bus_idle(ID_1, mem_bus_1);

            --------------------------------------------------------------------
            -- Check that unit is now idle since it is after transmittion already
            --------------------------------------------------------------------
            get_controller_status(status, ID_1, mem_bus_1);
            if (not status.bus_status) then
                outcome := false;
            end if;

        end if;

        ------------------------------------------------------------------------
        -- Erase the error counter. We need node 1 to be error active since when
        -- transmittion is aborted in last bit of crc field then Unit 2 sends
        -- ack and unit 1 ddetects it as SOF and then starts sending error frame.
        -- This needs to be active error frame otherwise unit 2 will never
        -- hook up by error frame and test will stuck in infinite loop!
        ------------------------------------------------------------------------
        err_counters.err_norm   := 0;
        err_counters.err_fd     := 0;
        err_counters.rx_counter := 0;
        err_counters.tx_counter := 0;
        set_error_counters(err_counters, ID_1, mem_bus_1);

  end procedure;

end package body;
