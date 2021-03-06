--------------------------------------------------------------------------------
-- 
-- CTU CAN FD IP Core
-- Copyright (C) 2015-2018
-- 
-- Authors:
--     Ondrej Ille <ondrej.ille@gmail.com>
--     Martin Jerabek <martin.jerabek01@gmail.com>
-- 
-- Project advisors: 
-- 	Jiri Novak <jnovak@fel.cvut.cz>
-- 	Pavel Pisa <pisa@cmp.felk.cvut.cz>
-- 
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
--  Event logger - supporting logging of events like : SOF start, Arbitration 
--  start, Arbitration lost, Message was validly recieved, transcieved etc...  
--  Operates as FIFO memory. Recording is started by trigger condition which is 
--  also presettable. Only one event at time can be recoded. See IP function 
--  documentation to see which events can't be recorded simultaneously. When 
--  event occurs it saves code of the event and input timeStamp.          
--------------------------------------------------------------------------------
-- Revision History:
--    July 2015   Created file
--    18.12.2015  Logger memory inference changed from FF to SRAM, dual port. 
--                Async Read, sync write. Assumed automatical recognition by 
--                synthetiser. Memory_valid vector added as workaround for era-
--                sing whole logger memory at once. This vector is erased at once
--                and when write to memory is performed according bit of the 
--                vector is set. When memory is read then its content is retur-
--                ned only if according bit of memory_valid vector is set.  
--                Otherwise zeroes are returned.
--    16.5.2016   1. Added function for filling the memory of logger. More gene-
--                   ric approach now available.
--                2. Fixed wrong data during logging of Data Overrun event
--                3. Added PC_State signal for more comprehensible implementa-
--                   tion of conditions
--    26.5.2016   Added edge detection on error signals! Thus each error is 
--                logged only once as expected!
--
--    16.6.2016   Completely changed event logging mechanism! Added so called 
--                event harvesting. Edge is detected on each event source and 
--                stored into event_captured register. In next N clock cycles, 
--                N events are added into logger memory where N is amount of 
--                bits in event_captured in logic 1 (Number of simultaneos events). 
--                When multiple events are marked in event_captured, they are 
--                stored cycle by cycle from lowest index events to highest index
--                events! Once event is truly stored into the buffer event cap-
--                tured bit is cleared! This mechanism is called "Event 
--                Harvesting"! Harvest pointer is combinationally decoded based 
--                on what content is in event_captured!  Additionaly with Event 
--                harvesting CAN controller reached better timing analysis and 
--                less LUT usage with same settings!
--    06.3.2018   Changed coding of Event details. Created "numerical" and 
--                "additional" details fields.
--------------------------------------------------------------------------------

Library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.ALL;
use ieee.math_real.ALL;

Library work;
use work.id_transfer.all;
use work.can_constants.all;
use work.can_components.all;
use work.can_types.all;
use work.cmn_lib.all;
use work.drv_stat_pkg.all;
use work.endian_swap.all;
use work.reduce_lib.all;

use work.CAN_FD_register_map.all;
use work.CAN_FD_frame_format.all;


entity event_logger is 
    generic(
        constant memory_size        :     natural := 16 --Only 2^k possible!
    );
    port(
        ------------------------------------------------------------------------
        -- Clock and reset
        ------------------------------------------------------------------------
        signal clk_sys              :in   std_logic;
        signal res_n                :in   std_logic;

        ------------------------------------------------------------------------
        -- Driving signals 
        ------------------------------------------------------------------------
        signal drv_bus              :in   std_logic_vector(1023 downto 0);
        signal stat_bus             :in   std_logic_vector(511 downto 0);
        signal sync_edge            :in   std_logic;
        signal data_overrun         :in   std_logic;
        signal timestamp            :in   std_logic_vector(63 downto 0);

        signal bt_FSM               :in   bit_time_type;

        -------------------
        --Status signals --
        -------------------

        --Logger finished interrrupt output
        signal loger_finished       :out  std_logic;
         
        signal loger_act_data       :out  std_logic_vector(63 downto 0);
        signal log_write_pointer    :out  std_logic_vector(7 downto 0);
        signal log_read_pointer     :out  std_logic_vector(7 downto 0);
        signal log_size             :out  std_logic_vector(7 downto 0);
        signal log_state_out        :out  logger_state_type

    );
end entity;


architecture rtl of event_logger is

    ----------------------------------------------------------------------------
    -- Internal registers and signals
    ----------------------------------------------------------------------------
    type logger_memory_type is array 
        (0 to memory_size - 1) of std_logic_vector(63 downto 0);

    -- Event count
    constant ev_cnt               :     natural := 21;

    signal memory                 :     logger_memory_type;
    signal memory_valid           :     std_logic_vector(0 to memory_size - 1);

    signal log_state              :     logger_state_type;
    signal log_state_reg          :     logger_state_type;

    signal read_pointer           :     natural range 0 to memory_size - 1;
    signal write_pointer          :     natural range 0 to memory_size - 1; 

    signal PC_state               :     protocol_type;

    ----------------------------------------------------------------------------
    -- Event harvester signals
    ----------------------------------------------------------------------------
    signal event_inputs           :     std_logic_vector(ev_cnt - 1 downto 0);
    signal event_register         :     std_logic_vector(ev_cnt - 1 downto 0);
    signal event_edge             :     std_logic_vector(ev_cnt - 1 downto 0);
    signal event_captured         :     std_logic_vector(ev_cnt - 1 downto 0);

    signal harvest_pointer        :     natural range 0 to 31;

    signal error_type_vect        :     std_logic_vector(4 downto 0);
    signal bit_type_vect          :     std_logic_vector(3 downto 0);

    signal s_up                   :     std_logic;

    signal ev_det                 :     std_logic_vector(4 downto 0);
    signal ev_den                 :     std_logic_vector(2 downto 0);
    signal ev_dea                 :     std_logic_vector(2 downto 0);

    ----------------------------------------------------------------------------
    -- Driving bus aliases
    ----------------------------------------------------------------------------    
    signal   drv_trig_sof         :     std_logic;
    signal   drv_trig_arb_lost    :     std_logic;
    signal   drv_trig_rec_valid   :     std_logic;
    signal   drv_trig_tran_valid  :     std_logic;
    signal   drv_trig_ovl         :     std_logic;
    signal   drv_trig_error       :     std_logic;
    signal   drv_trig_brs         :     std_logic;
    signal   drv_trig_user_write  :     std_logic;
    signal   drv_trig_arb_start   :     std_logic;
    signal   drv_trig_contr_start :     std_logic;
    signal   drv_trig_data_start  :     std_logic;
    signal   drv_trig_crc_start   :     std_logic;
    signal   drv_trig_ack_rec     :     std_logic;
    signal   drv_trig_ack_n_rec   :     std_logic;
    signal   drv_trig_ewl_reached :     std_logic;
    signal   drv_trig_erp_changed :     std_logic;
    signal   drv_trig_tran_start  :     std_logic;
    signal   drv_trig_rec_start   :     std_logic;
    signal   drv_cap_sof          :     std_logic;
    signal   drv_cap_arb_lost     :     std_logic;
    signal   drv_cap_rec_valid    :     std_logic;
    signal   drv_cap_tran_valid   :     std_logic;
    signal   drv_cap_ovl          :     std_logic;
    signal   drv_cap_error        :     std_logic;
    signal   drv_cap_brs          :     std_logic;
    signal   drv_cap_arb_start    :     std_logic;
    signal   drv_cap_contr_start  :     std_logic;
    signal   drv_cap_data_start   :     std_logic;
    signal   drv_cap_crc_start    :     std_logic;
    signal   drv_cap_ack_rec      :     std_logic;
    signal   drv_cap_ack_n_rec    :     std_logic;
    signal   drv_cap_ewl_reached  :     std_logic;
    signal   drv_cap_erp_changed  :     std_logic;
    signal   drv_cap_tran_start   :     std_logic;
    signal   drv_cap_rec_start    :     std_logic;
    signal   drv_cap_sync_edge    :     std_logic;
    signal   drv_cap_stuffed      :     std_logic;
    signal   drv_cap_destuffed    :     std_logic;
    signal   drv_cap_ovr          :     std_logic;
    signal   drv_log_cmd_str      :     std_logic;
    signal   drv_log_cmd_abt      :     std_logic;
    signal   drv_log_cmd_up       :     std_logic;
    signal   drv_log_cmd_down     :     std_logic;

begin
  
    ----------------------------------------------------------------------------
    -- Memory to output propagation
    ----------------------------------------------------------------------------s
    log_write_pointer            <=  std_logic_vector(to_unsigned(
                                        write_pointer, 8));

    log_read_pointer             <=  std_logic_vector(to_unsigned(
                                        read_pointer, 8));

    log_size                     <=  std_logic_vector(to_unsigned(
                                        memory_size, 8));

    log_state_out                <=  log_state;

  
    ----------------------------------------------------------------------------
    -- Driving bus aliases
    ----------------------------------------------------------------------------
    drv_trig_sof                 <=  drv_bus(DRV_TRIG_SOF_INDEX);
    drv_trig_arb_lost            <=  drv_bus(DRV_TRIG_ARB_LOST_INDEX);
    drv_trig_rec_valid           <=  drv_bus(DRV_TRIG_REC_VALID_INDEX);
    drv_trig_tran_valid          <=  drv_bus(DRV_TRIG_TRAN_VALID_INDEX);
    drv_trig_ovl                 <=  drv_bus(DRV_TRIG_OVL_INDEX);
    drv_trig_error               <=  drv_bus(DRV_TRIG_ERROR_INDEX);
    drv_trig_brs                 <=  drv_bus(DRV_TRIG_BRS_INDEX);
    drv_trig_user_write          <=  drv_bus(DRV_TRIG_USER_WRITE_INDEX);
    drv_trig_arb_start           <=  drv_bus(DRV_TRIG_ARB_START_INDEX);
    drv_trig_contr_start         <=  drv_bus(DRV_TRIG_CONTR_START_INDEX);
    drv_trig_data_start          <=  drv_bus(DRV_TRIG_DATA_START_INDEX);
    drv_trig_crc_start           <=  drv_bus(DRV_TRIG_CRC_START_INDEX);
    drv_trig_ack_rec             <=  drv_bus(DRV_TRIG_ACK_REC_INDEX);
    drv_trig_ack_n_rec           <=  drv_bus(DRV_TRIG_ACK_N_REC_INDEX);
    drv_trig_ewl_reached         <=  drv_bus(DRV_TRIG_EWL_REACHED_INDEX);
    drv_trig_erp_changed         <=  drv_bus(DRV_TRIG_ERP_CHANGED_INDEX);
    drv_trig_tran_start          <=  drv_bus(DRV_TRIG_TRAN_START_INDEX);
    drv_trig_rec_start           <=  drv_bus(DRV_TRIG_REC_START_INDEX);

    drv_cap_sof                  <=  drv_bus(DRV_CAP_SOF_INDEX);
    drv_cap_arb_lost             <=  drv_bus(DRV_CAP_ARB_LOST_INDEX);
    drv_cap_rec_valid            <=  drv_bus(DRV_CAP_REC_VALID_INDEX);
    drv_cap_tran_valid           <=  drv_bus(DRV_CAP_TRAN_VALID_INDEX);
    drv_cap_ovl                  <=  drv_bus(DRV_CAP_OVL_INDEX);
    drv_cap_error                <=  drv_bus(DRV_CAP_ERROR_INDEX);
    drv_cap_brs                  <=  drv_bus(DRV_CAP_BRS_INDEX);
    drv_cap_arb_start            <=  drv_bus(DRV_CAP_ARB_START_INDEX);
    drv_cap_contr_start          <=  drv_bus(DRV_CAP_CONTR_START_INDEX);
    drv_cap_data_start           <=  drv_bus(DRV_CAP_DATA_START_INDEX);
    drv_cap_crc_start            <=  drv_bus(DRV_CAP_CRC_START_INDEX);
    drv_cap_ack_rec              <=  drv_bus(DRV_CAP_ACK_REC_INDEX);
    drv_cap_ack_n_rec            <=  drv_bus(DRV_CAP_ACK_N_REC_INDEX);
    drv_cap_ewl_reached          <=  drv_bus(DRC_CAP_EWL_REACHED_INDEX);
    drv_cap_erp_changed          <=  drv_bus(DRV_CAP_ERP_CHANGED_INDEX);
    drv_cap_tran_start           <=  drv_bus(DRV_CAP_TRAN_START_INDEX);
    drv_cap_rec_start            <=  drv_bus(DRV_CAP_REC_START_INDEX);
    drv_cap_sync_edge            <=  drv_bus(DRV_CAP_SYNC_EDGE_INDEX);
    drv_cap_stuffed              <=  drv_bus(DRV_CAP_STUFFED_INDEX);
    drv_cap_destuffed            <=  drv_bus(DRV_CAP_DESTUFFED_INDEX);
    drv_cap_ovr                  <=  drv_bus(DRV_CAP_OVR_INDEX);

    drv_log_cmd_str              <=  drv_bus(DRV_LOG_CMD_STR_INDEX);
    drv_log_cmd_abt              <=  drv_bus(DRV_LOG_CMD_ABT_INDEX);
    drv_log_cmd_up               <=  drv_bus(DRV_LOG_CMD_UP_INDEX);
    drv_log_cmd_down             <=  drv_bus(DRV_LOG_CMD_DOWN_INDEX);
   
    -- Memory propagation only if given field is valid
    loger_act_data               <=  memory(read_pointer) 
                                    when (memory_valid(read_pointer) = '1') 
                                    else 
                                    (OTHERS => '0');
  
    -- Protocol control state from status bus
    PC_state           <= protocol_type'VAL
                        (to_integer(unsigned(
                         stat_bus(STAT_PC_STATE_HIGH downto STAT_PC_STATE_LOW))
                         ));
  
  
    ----------------------------------------------------------------------------
    -- Here we join the event sources into input vector
    ----------------------------------------------------------------------------
    event_inputs (0)    <= '1' when ((drv_cap_sof ='1') and (PC_state = sof))                 
                               else 
                           '0';

    event_inputs (1)    <= drv_cap_arb_lost and stat_bus(STAT_ARB_LOST_INDEX);

    event_inputs (2)    <= drv_cap_rec_valid and stat_bus(STAT_REC_VALID_INDEX);

    event_inputs (3)    <= drv_cap_tran_valid and stat_bus(STAT_TRAN_VALID_INDEX);

    event_inputs (4)    <= '1' when (drv_cap_ovl = '1') and 
                                    (PC_state = overload) 
                               else
                           '0';

    event_inputs (5)    <= drv_cap_error and (stat_bus(STAT_ERROR_VALID_INDEX));

    event_inputs (6)    <= drv_cap_brs and stat_bus(STAT_BR_SHIFTED);

    event_inputs (7)      <= '1' when (drv_cap_arb_start = '1') and 
                                      (PC_state = arbitration)
                               else
                             '0';

    event_inputs (8)      <= '1' when (drv_cap_contr_start = '1') and 
                                      (PC_state = control)
                                 else
                             '0';

    event_inputs (9)      <= '1' when (drv_cap_data_start = '1')  and 
                                      (PC_state = data)
                                 else
                             '0';

    event_inputs (10)     <= '1' when (drv_cap_crc_start = '1') and 
                                      (PC_state = crc)
                                 else
                             '0';

    event_inputs (11)     <= drv_cap_ack_rec and 
                             stat_bus(STAT_ACK_RECIEVED_OUT_INDEX);

    event_inputs (12)     <= drv_cap_ack_n_rec and 
                             stat_bus(STAT_ACK_ERROR_INDEX);

    event_inputs (13)     <= drv_cap_ewl_reached and 
                             stat_bus(STAT_EWL_REACHED_INDEX);

    event_inputs (14)     <= drv_cap_erp_changed and 
                             stat_bus(STAT_ERP_CHANGED_INDEX);

    event_inputs (15)     <= drv_cap_tran_start and 
                             stat_bus(STAT_SET_TRANSC_INDEX);

    event_inputs (16)     <= drv_cap_rec_start and stat_bus(STAT_SET_REC_INDEX);

    event_inputs (17)     <= drv_cap_sync_edge and sync_edge;

    event_inputs (18)     <= drv_cap_stuffed and stat_bus(STAT_DATA_HALT_INDEX);

    event_inputs (19)     <= drv_cap_destuffed and 
                             stat_bus(STAT_DESTUFFED_INDEX);

    event_inputs (20)     <= drv_cap_ovr and data_overrun;

  
    ----------------------------------------------------------------------------
    -- Registering previous values, to detect change.
    ----------------------------------------------------------------------------
    in_vect_reg_proc : process(res_n, clk_sys)
    begin
        if (res_n = ACT_RESET) then
            event_register <= (OTHERS => '0');
            log_state_reg  <= config;
        elsif rising_edge(clk_sys) then
            event_register <= event_inputs;
            log_state_reg  <= log_state;
        end if;
    end process;
  
 
    -- Combinational edge detection of edge
    event_edge <= event_inputs and (not event_register);


    ----------------------------------------------------------------------------
    -- Pointer decoder for event harvesting
    ----------------------------------------------------------------------------
    harv_ctr_proc : process(event_captured)
    begin
        harvest_pointer <= ev_cnt;
        for i in 0 to ev_cnt - 1 loop
            if (event_captured(i) = '1') then
                harvest_pointer <= i;
            end if;
        end loop;
    end process;

  
    -- After bit rate shift, "sp_control" is updated. Depending on new 
    -- "sp_control", we can find out what kind of shift happened.
    s_up <= '0' when (stat_bus(STAT_SP_CONTROL_HIGH downto STAT_SP_CONTROL_LOW)
                      = NOMINAL_SAMPLE)
                else
            '1';

    ----------------------------------------------------------------------------
    -- Event details decoding!
    ----------------------------------------------------------------------------
    ev_det      <=  error_type_vect 
                      when harvest_pointer = 5 else
                
                    "0000" & s_up
                          when harvest_pointer = 6 else
                       
                    "0" & bit_type_vect  
                          when harvest_pointer = 17 else
                            
                    "0000" & stat_bus(STAT_FIXED_STUFF_INDEX)
                          when harvest_pointer = 18 else
                            
                    "0000" & stat_bus(STAT_FIXED_DESTUFF_INDEX)
                          when harvest_pointer = 19 else
                    (OTHERS => '0');

    ev_den     <=   stat_bus(STAT_BS_LENGTH_HIGH downto STAT_BS_LENGTH_LOW)  
                      when harvest_pointer = 18 else
                
                    stat_bus(STAT_BDS_LENGTH_HIGH downto STAT_BDS_LENGTH_LOW)  
                      when harvest_pointer = 19 else    
                
                    (OTHERS => '0');
                 
                 
    ev_dea     <= '0' & stat_bus(STAT_SYNC_CONTROL_HIGH downto 
                                 STAT_SYNC_CONTROL_LOW)  
                    when harvest_pointer = 17 else     
                    (OTHERS => '0');

  
    ----------------------------------------------------------------------------
    -- Process for event harvesting
    ----------------------------------------------------------------------------
    ev_harv_proc : process(clk_sys, res_n)
    begin
        if (res_n = ACT_RESET) then
            event_captured  <= (OTHERS => '0');
            write_pointer   <= 0;
            memory_valid    <= (OTHERS => '0');
            
            -- pragma translate_off
            memory          <= (OTHERS => (OTHERS => '0'));
            -- pragma translate_on

            -- Special event details
            error_type_vect <= (OTHERS => '0');
            bit_type_vect   <= (OTHERS => '0');
            
        elsif rising_edge(clk_sys) then
            
            event_captured  <=  event_captured;
            write_pointer   <=  write_pointer;
            memory_valid    <=  memory_valid;
            
            error_type_vect <= error_type_vect;
            bit_type_vect   <= bit_type_vect;
            
            --Erase the harvester in the beginning
            if (log_state_reg = config and log_state = ready) then
                write_pointer   <= 0;
                memory_valid    <= (OTHERS => '0');
              
            elsif (log_state_reg = ready and (log_state = running)) then
                event_captured  <= (OTHERS => '0');
              
            elsif (log_state = running) then

                ----------------------------------------------------------------
                -- Record that event happend on the edge into event_captured
                ----------------------------------------------------------------
                for i in 0 to ev_cnt - 1 loop
                    if (event_captured(i) = '0') then
                        if (event_edge(i) = '1') then
                            event_captured(i) <= '1';

                            -- Here some additional stuff need to be stored 
                            -- in special event types
                            if (i = 5) then
                                error_type_vect <=
                                    stat_bus(STAT_FORM_ERROR_INDEX) &
                                    stat_bus(STAT_ACK_ERROR_INDEX) &
                                    stat_bus(STAT_CRC_ERROR_INDEX) &
                                    stat_bus(STAT_STUFF_ERROR_INDEX) &
                                    stat_bus(STAT_BIT_ERROR_VALID_INDEX);
                            end if;                  

                            if (i = 17) then
                                case bt_FSM is
                                    when tseg1   => bit_type_vect <= "0001"; 
                                    when tseg2   => bit_type_vect <= "1000";
                                    when others  => bit_type_vect <= "0000";
                                end case;
                            end if; 
                          
                        end if;
                    end if;
                end loop;

                ----------------------------------------------------------------
                -- Here browse (harwest) trough "event_captured" and store it 
                -- into the actuall logger memory!!! We do it sequentially from
                -- lowest indices up to highest indices Here harvest_pointer is
                -- used. This pointer is decoded by priority decoder and allows
                -- sequential processing of many events happening simulateously!
                ----------------------------------------------------------------
                if (harvest_pointer < ev_cnt) then
                    event_captured(harvest_pointer) <= '0';
                    memory_valid(write_pointer)     <= '1';

                    -- Store the data into logger
                    memory(write_pointer)   <= timestamp(47 downto 0) &
                                               ev_dea &
                                               ev_det &
                                               ev_den &
                                               std_logic_vector(to_unsigned(
                                               harvest_pointer + 1, 5));
                    write_pointer           <= (write_pointer + 1) mod
                                               memory_size;
                end if;          
            end if;
            
        end if;  
    end process;
  
  
    ----------------------------------------------------------------------------
    -- The main logging state machine
    ----------------------------------------------------------------------------
    log_proc : process(clk_sys, res_n)
    begin
        if (res_n = ACT_RESET) then
            log_state                 <= config;
            loger_finished            <= '0';

        elsif rising_edge(clk_sys)then       
            log_state                 <=  log_state;    

            case log_state is      
            --------------------------------------------------------------------
            -- Configuration state - Logger waiting to be started
            --------------------------------------------------------------------
            when config =>
                
                if (drv_log_cmd_str = '1') then
                    log_state         <=  ready;
                end if;
                
            --------------------------------------------------------------------
            -- Ready state         - Logger Waiting for trigger
            --------------------------------------------------------------------
            when ready =>
                --Abort -> Move to Config State
                loger_finished    <=  '0';
                if (drv_log_cmd_abt = '1') then
                    log_state         <=  config;
                else
                  
                 ---------------------------------------------------------------
                 -- Checking if some of the trigger conditions appeared
                 ---------------------------------------------------------------
                 if (((drv_trig_sof = '1')         and (PC_state = sof)) or
                     ((drv_trig_arb_start = '1')   and (PC_state = arbitration)) or   
                     ((drv_trig_contr_start = '1') and (PC_state = control)) or   
                     ((drv_trig_data_start = '1')  and (PC_state = data)) or   
                     ((drv_trig_crc_start = '1')   and (PC_state = crc)))
                 then   
                      log_state     <=  running;
                 end if;  
                 
                 if ((((drv_trig_arb_lost    = '1') and 
                    stat_bus(STAT_ARB_LOST_INDEX)    = '1')) or
                 (((drv_trig_rec_valid   = '1') and
                    stat_bus(STAT_REC_VALID_INDEX)   = '1')) or
                 (((drv_trig_tran_valid  = '1') and 
                    stat_bus(STAT_TRAN_VALID_INDEX)  = '1')) or
                 (((drv_trig_ovl         = '1') and 
                    (PC_state                        =  overload))) or
                 (((drv_trig_brs         = '1') and 
                    stat_bus(STAT_TRAN_BRS_INDEX)    = '1')) or
                 (((drv_trig_ack_n_rec   = '1') and 
                    stat_bus(STAT_ACK_ERROR_INDEX)   = '1')) or
                 (((drv_trig_ewl_reached = '1') and 
                    stat_bus(STAT_EWL_REACHED_INDEX) = '1')) or
                 (((drv_trig_erp_changed = '1') and 
                    stat_bus(STAT_ERP_CHANGED_INDEX) = '1')) or
                 (((drv_trig_tran_start  = '1') and 
                    stat_bus(STAT_SET_TRANSC_INDEX)  = '1')) or
                 (((drv_trig_brs  = '1') and 
                    stat_bus(STAT_BR_SHIFTED)  = '1')) or
                 (((drv_trig_rec_start   = '1') and 
                    stat_bus(STAT_SET_REC_INDEX)     = '1')) or
                    -- Note: Two writes have to be done now to command bit
                 (((drv_trig_user_write  = '1') and 
                    drv_log_cmd_str                  = '1')) or 
                 (((drv_trig_error       = '1') and 
                    stat_bus(STAT_ERROR_VALID_INDEX) = '1')) or 
                 (((drv_trig_ack_rec     = '1') and 
                    stat_bus(STAT_ACK_RECIEVED_OUT_INDEX) = '1'))
                ) then
                   log_state    <=  running;
                end if;
                end if;

            --------------------------------------------------------------------
            -- Event logger is running
            --------------------------------------------------------------------    
            when running =>
                loger_finished        <=  '0';

                -- Stop the logging when abort command or buffer full
                if ((drv_log_cmd_abt = '1') or 
                    (write_pointer = memory_size - 1))
                then
                    log_state           <=  config;
                    if (write_pointer = memory_size - 1) then
                        loger_finished    <=  '1';
                    end if;            
                end if;

            when others => 
            end case;   
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- Process for read pointer manipulation
    ----------------------------------------------------------------------------
    read_point_proc : process(clk_sys, res_n)
    begin
        if (res_n = ACT_RESET) then
            read_pointer        <=  0;
        elsif rising_edge(clk_sys) then
          
            if ((drv_log_cmd_up   = '1') and 
                (drv_log_cmd_down = '0'))
            then
                read_pointer      <= (read_pointer + 1) mod memory_size;

            elsif ((drv_log_cmd_up   = '0') and 
                   (drv_log_cmd_down = '1'))
            then
                read_pointer      <= (read_pointer + 1) mod memory_size;
            else
                read_pointer      <= read_pointer;
            end if;

        end if;
    end process;


    ----------------------------------------------------------------------------
    -- Event logger size can be only powers of 2. Since modulo arithmetics
    -- is used on memory pointers, using non power of 2 value would result
    -- in increased logic usage!
    ----------------------------------------------------------------------------
    assert ((memory_size = 8) or
            (memory_size = 16) or
            (memory_size = 32) or
            (memory_size = 64) or
            (memory_size = 128) or
            (memory_size = 256) or
            (memory_size = 512) or
            (memory_size = 1024))
    report "Unsupported Event logger memory size! Only powers of 2 are valid!"
    severity failure;
  
end architecture;
