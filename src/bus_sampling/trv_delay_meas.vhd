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
--  Measurement of Transceiver delay and calculation of secondary sampling
--  point offset.
-- 
--  Measurement is started via "meas_start" signal and stopped via "meas_stop"
--  signal. Measurement is performed only when "meas_enable" is active, otherwise
--  transceiver delay counter remains unchanged even upon "meas_start" or 
--  "meas_stop" signals.
-- 
--  Secondary sampling point is shadowed during measurement and propagated to 
--  output after the measurement. Data are loaded to output register upon the end
--  of transceiver delay measurement and kept stable till the end of next
--  measurement. Configurable offset "ssp_offset" is implemented.
--
--  Shadowed value is muxed based on "ssp_delay_select":
--    1. Measured value only.
--    2. Measured value + configured offset.
--    3. Configured offset only.
--
-- Circuit has following diagram:
--  
--            SSP Delay select
--  ------------------------------------+
--                                      |   
--  Start Measurement                   |
--  ------------|                       |
--              |                       |
--   Stop       |                       |
--  Measur.     |                       |
--  ------      |                       |
--       |      |                       |
--       v      v                       |   Shadow registers
--   +--------------+                   |        load
--   |  Measurement +-------------------------------------------+
--   |     Flag     |                   |                       |
--   +------+-------+                   |                       |
--          |                           |                       |
--          | Measurement progress      |                       v
--          |                           |                  |----------|  TRV
--          |               ------------|------------------|  Shadow  | Delay
--          |               |           |                  | register |-------->
--   +------v-------+  Transceiver  XX  |                  |----------|
--   |  Transceiver |    Delay      | X v                       |
--   |     Delay    +-------+-----> |  X                        |
--   |    Counter   |       |       |   X                       v
--   +--------------+    +--v--+    |    X  |------------|  |----------|  SSP
--    SSP offset         |     |    |    X  |            |  |  Shadow  | Offset
--  -------------------> |  +  +--> |    X+-| Saturation |->+ register |------->
--                       |     |    |    X  |            |  |          |
--                       +-----+    |   X   |------------|  |----------|
--                                  |  X                    
--                                  | X                     
--                                  XX 
--
--------------------------------------------------------------------------------
--    02.01.2019  Created file
--    28.05.2019  Modified to use only offset and offset + measured value!
--------------------------------------------------------------------------------

Library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.ALL;

Library work;
use work.id_transfer.all;
use work.can_constants.all;
use work.can_components.all;
use work.can_types.all;
use work.cmn_lib.all;
use work.drv_stat_pkg.all;
use work.reduce_lib.all;

use work.CAN_FD_register_map.all;
use work.CAN_FD_frame_format.all;

entity trv_delay_measurement is
    generic(
        -- Reset polarity
        G_RESET_POLARITY         :     std_logic;
        
        -- Width (number of bits) in transceiver delay measurement counter
        G_TRV_CTR_WIDTH          :     natural := 7;
        
        -- Optional usage of saturated value of ssp_delay 
        G_USE_SSP_SATURATION     :     boolean := true;
        
        -- Saturation level for size of SSP_delay. This is to make sure that
        -- if there is smaller shift register for secondary sampling point we
        -- don't address outside of this register.
        G_SSP_SATURATION_LVL     :     natural
    );
    port(
        ------------------------------------------------------------------------
        -- Clock and Asynchronous reset
        ------------------------------------------------------------------------
        -- System clock
        clk_sys             :in   std_logic;
        
        -- Asynchronous reset        
        res_n               :in   std_logic;

        ------------------------------------------------------------------------
        -- Transceiver Delay measurement control
        ------------------------------------------------------------------------
        -- Start measurement (on TX Edge)
        meas_start          :in   std_logic;
        
        -- Stop measurement (on RX Edge)
        meas_stop           :in   std_logic;
        
        -- Measurement enabled (by Protocol control)
        meas_enable         :in   std_logic;

        ------------------------------------------------------------------------
        -- Memory registers interface
        ------------------------------------------------------------------------
        -- Secondary sampling point offset
        ssp_offset          :in   std_logic_vector(G_TRV_CTR_WIDTH - 1 downto 0);

        -- Source of secondary sampling point 
        -- (Measured, Offset, Measured and Offset)
        ssp_delay_select    :in   std_logic_vector(1 downto 0);

        ------------------------------------------------------------------------
        -- Status outputs
        ------------------------------------------------------------------------
        -- Transceiver delay measurement is in progress
        trv_meas_progress   :out  std_logic;
        
        -- Shadowed value of Transceiver delay. Updated when measurement ends.
        trv_delay_shadowed  :out  std_logic_vector(G_TRV_CTR_WIDTH - 1 downto 0);
                                               
        -- Shadowed value of SSP configuration. Updated when measurement ends.
        ssp_delay_shadowed  :out  std_logic_vector(G_TRV_CTR_WIDTH downto 0)
    );
end entity;

architecture rtl of trv_delay_measurement is
    
    -- Transceiver delay measurement next value
    signal trv_meas_progress_nxt  :    std_logic;

    -- Transceiver delay measurement - internal register value
    signal trv_meas_progress_i    :    std_logic;
    
    -- Delayed value of trv_meas_progress to detect when measurement has ended
    -- and load ssp_offset shadow register.
    signal trv_meas_progress_del  :    std_logic;

    ---------------------------------------------------------------------------
    -- Transceiver delay counter
    ---------------------------------------------------------------------------
    signal trv_delay_ctr_reg   :  std_logic_vector(G_TRV_CTR_WIDTH - 1 downto 0);
    signal trv_delay_ctr_rst   :  std_logic;
    signal trv_delay_ctr_add   :  std_logic_vector(G_TRV_CTR_WIDTH - 1 downto 0);

    ---------------------------------------------------------------------------
    -- SSP Shadowed register
    ---------------------------------------------------------------------------
    signal ssp_shadowed_nxt    :  std_logic;

    -- Load shadow register to output
    signal ssp_shadow_load     :  std_logic;

    ---------------------------------------------------------------------------
    -- Shadowed value of transceiver delay counter
    ---------------------------------------------------------------------------
    -- Note that output counter is one bit wider than width of counter since
    -- output value can be addition of two values of trv_ctr_width size and
    -- we want to avoid overflow.
    signal ssp_delay_nxt        :  std_logic_vector(G_TRV_CTR_WIDTH downto 0);

    -- Saturated value of ssp_delay. If saturation is not used, ssp_delay_nxt
    -- is connected directly
    signal ssp_delay_saturated  :  std_logic_vector(G_TRV_CTR_WIDTH downto 0);
                                           
    -- Measured transceiver value + trv_offset
    signal trv_delay_sum        :  std_logic_vector(G_TRV_CTR_WIDTH downto 0);

begin
    
    ----------------------------------------------------------------------------
    -- Next value of transceiver delay measurment flag:
    --  1. Clear immediately when measurement is disabled.
    --  2. Start measurement when enabled and "meas_start"
    --  3. Stop measurement when enabled  and "meas_stop"
    --  4. Keep value otherwise.
    ----------------------------------------------------------------------------
    trv_meas_progress_nxt <= '0' when (meas_enable = '0') else
                             '1' when (meas_start = '1') else
                             '0' when (meas_stop = '1') else
                             trv_meas_progress_i;

    ----------------------------------------------------------------------------
    -- Register for transceiver delay measurement progress flag.
    ----------------------------------------------------------------------------
    trv_delay_prog_proc : process(res_n, clk_sys)
    begin
        if (res_n = G_RESET_POLARITY) then
            trv_meas_progress_i     <= '0';
            trv_meas_progress_del   <= '0';
        elsif (rising_edge(clk_sys)) then
            trv_meas_progress_i     <= trv_meas_progress_nxt;
            trv_meas_progress_del   <= trv_meas_progress_i;
        end if;
    end process;
    
    ----------------------------------------------------------------------------
    -- Reset counter for transceiver delay upon start of measurement.
    ----------------------------------------------------------------------------
    trv_delay_ctr_rst <= '1' when (meas_enable = '1' and meas_start = '1') else
                         '0'; 
    
    ----------------------------------------------------------------------------
    -- Combinationally incremented value of trv_delay counter by 1.
    ----------------------------------------------------------------------------                                             
    trv_delay_ctr_add <= std_logic_vector(to_unsigned(
                            to_integer(unsigned(trv_delay_ctr_reg) + 1),
                            trv_delay_ctr_reg'length));                     

    ----------------------------------------------------------------------------
    -- Register for transceiver delay measurement progress flag.
    ----------------------------------------------------------------------------
    trv_del_ctr_proc : process(res_n, clk_sys, trv_delay_ctr_rst)
    begin
        if (res_n = G_RESET_POLARITY or trv_delay_ctr_rst = '1') then
            trv_delay_ctr_reg <= (OTHERS => '0');
            
        elsif (rising_edge(clk_sys)) then
            
            -- Increment the counter if the measurement is in progress
            if (trv_meas_progress_i = '1') then
                trv_delay_ctr_reg <= trv_delay_ctr_add;
            end if;
        end if;
    end process;


    ---------------------------------------------------------------------------
    -- Combinationally adding ssp_offset and trv_delay_ctr_reg
    ---------------------------------------------------------------------------
    trv_delay_sum <= std_logic_vector(to_unsigned(
                        to_integer(unsigned(trv_delay_ctr_reg)) +
                        to_integer(unsigned(ssp_offset)), trv_delay_sum'length));
                        

    ----------------------------------------------------------------------------
    -- Multiplexor for selected secondary sampling point delay. Selects:
    --  1. Measured trv_delay + ssp_offset
    --  2. ssp_offset only.
    ----------------------------------------------------------------------------
    with ssp_delay_select select ssp_delay_nxt <=
                  trv_delay_sum when SSP_SRC_MEAS_N_OFFSET,
               '0' & ssp_offset when SSP_SRC_OFFSET,
                (OTHERS => '0') when others;

    ----------------------------------------------------------------------------
    -- SSP Delay saturation
    ----------------------------------------------------------------------------
    ssp_delay_sat_block : block
        constant ssp_delay_range  : natural := 2 ** ssp_delay_nxt'length - 1;
        signal ssp_delay_nxt_int  : natural range 0 to ssp_delay_range;
        signal ssp_delay_sat_int  : natural range 0 to ssp_delay_range;
    begin
        ssp_delay_nxt_int   <= to_integer(unsigned(ssp_delay_nxt));

        -- Use saturation
        ssp_sat_true : if (G_USE_SSP_SATURATION) generate

            -- Saturate on "natural" types
            ssp_delay_sat_int <=
                G_SSP_SATURATION_LVL when (ssp_delay_nxt_int > G_SSP_SATURATION_LVL)
                                     else
                ssp_delay_nxt_int;

            -- Convert natural back to vector
            ssp_delay_saturated <= std_logic_vector(to_unsigned(
                                    ssp_delay_sat_int, ssp_delay_saturated'length));

        end generate ssp_sat_true;

        -- Don't use saturation
        ssp_sat_false : if (not G_USE_SSP_SATURATION) generate
            ssp_delay_saturated <= ssp_delay_nxt;
        end generate ssp_sat_false;
        
    end block ssp_delay_sat_block;


    ---------------------------------------------------------------------------
    -- SSP Shadow register. Both values are captured at the end of measurement.
    --  1. Transceiver Delay - Only measured value
    --  2. SSP Offset - Selected between measured, measured + offset,
    --                  offset.
    ---------------------------------------------------------------------------
    ssp_shadow_reg_proc : process(res_n, clk_sys)
    begin
        if (res_n = G_RESET_POLARITY) then
            ssp_delay_shadowed   <= (OTHERS => '0');
            trv_delay_shadowed   <= (OTHERS => '0');
            
        elsif (rising_edge(clk_sys)) then
            if (ssp_shadow_load = '1') then
                ssp_delay_shadowed <= ssp_delay_saturated;
                trv_delay_shadowed <= trv_delay_ctr_reg;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Load shadow register for secondary sampling point after the end of
    -- secondary sampling point measurement. This must be after the measurement
    -- has already ended so that last value is taken, not the value decremented
    -- by 1!
    ---------------------------------------------------------------------------
    ssp_shadow_load <= '1' when (trv_meas_progress_del = '1') and
                                (trv_meas_progress_i = '0')
                           else
                       '0';

    ---------------------------------------------------------------------------
    -- Propagation of internal signals to output
    ---------------------------------------------------------------------------
    trv_meas_progress <= trv_meas_progress_i;

end architecture;