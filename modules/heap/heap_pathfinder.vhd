--! @file heap_pathfinder.vhd
--! @brief submodule of generic heap, calculates queue or dequeue path through the heap
--! @author Mathias Kreider <m.kreider@gsi.de>
--!
--! Copyright (C) 2013 GSI Helmholtz Centre for Heavy Ion Research GmbH 
--!
--! Calculates queue or dequeue path through the heap and outputs all indices 
--! which ought to be shifted in order of traversal along the path,
--! last index on the output is the new position of the moving element
--! 
--! Heap is organized as follows:
--! First element idx 1, last idx 2^g_idx_width -1 
--! right child of parent idx n is 2*n
--! right child of parent idx n is 2*n+1
--------------------------------------------------------------------------------
--! This library is free software; you can redistribute it and/or
--! modify it under the terms of the GNU Lesser General Public
--! License as published by the Free Software Foundation; either
--! version 3 of the License, or (at your option) any later version.
--!
--! This library is distributed in the hope that it will be useful,
--! but WITHOUT ANY WARRANTY; without even the implied warranty of
--! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
--! Lesser General Public License for more details.
--!  
--! You should have received a copy of the GNU Lesser General Public
--! License along with this library. If not, see <http://www.gnu.org/licenses/>.
---------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;


library work;
use work.genram_pkg.all;
use work.wishbone_pkg.all;
use work.gencores_pkg.all;
use work.heap_pkg.all;

entity heap_pathfinder is
  generic(
    g_idx_width    : natural := 8;
    g_key_width    : natural := 64
  );            
  port(
    clk_sys_i  : in  std_logic;
    rst_n_i    : in  std_logic;

    push_i     : in  std_logic;
    pop_i      : in  std_logic;
    movkey_i   : in  std_logic_vector(g_key_width-1 downto 0);
    busy_o     : out std_logic;
    empty_o    : out std_logic; 
    full_o     : out std_logic;
    
    -- to writer core
    final_o    : out std_logic;
    idx_o      : out std_logic_vector(g_idx_width-1 downto 0);
    last_o     : out std_logic_vector(g_idx_width-1 downto 0);
    valid_o    : out std_logic;    
    
    --from writer core
    wr_key_i   : in  std_logic_vector(g_key_width-1 downto 0);     -- writes
    wr_idx_i   : in  std_logic_vector(g_idx_width-1 downto 0);
    we_i       : in  std_logic
    );
end heap_pathfinder;

architecture behavioral of heap_pathfinder is

   constant c_elements : natural := 2**g_idx_width;
   subtype t_key   is std_logic_vector(g_key_width  -1 downto 0);
  
   
   subtype t_adr is std_logic_vector(g_idx_width-1 downto 0);
   type t_key_array is array (1 downto 0) of t_key;
   type t_adr_array is array (1 downto 0) of t_adr;
   signal s_aa, s_adr_down, s_adr_up, s_adr_def : t_adr_array;
   signal s_qa : t_key_array;
    
   type t_op_state is (e_IDLE, e_HEAP_UP, e_HEAP_UP_SETUP, e_HEAP_DOWN, e_HEAP_DOWN_SETUP, e_UPDATE);
   constant c_REMOVE   : std_logic_vector (1 downto 0)  := "01";
   constant c_INSERT   : std_logic_vector (1 downto 0)  := "10";
   constant c_REPLACE  : std_logic_vector (1 downto 0)  := "11";
   constant c_DEF      : std_logic_vector (1 downto 0)  := "00";
   constant c_DOWN     : std_logic_vector (1 downto 0)  := "01";
   constant c_UP       : std_logic_vector (1 downto 0)  := "10";
   
   
   signal r_state : t_op_state;
   signal r_last, r_new_last, r_ptr, s_ptr_down, s_l_child, s_r_child, s_ptr_up : unsigned(g_idx_width-1 downto 0); 
   constant c_first      : unsigned(g_idx_width-1 downto 0) := to_unsigned(1, g_idx_width); 
   signal r_mov : t_key;
   signal s_parent_le_children : std_logic;
--signal	r_parent_le_children : std_logic;
   signal s_lowest_level : std_logic;        
	--signal r_lowest_level       : std_logic;
   
   signal s_child_gre_parent : std_logic;
--	signal r_child_gre_parent   : std_logic;
   signal s_highest_level : std_logic; 
--	signal       r_highest_level      : std_logic; 
            
   signal s_pos_found, r_pos_found, s_valid : std_logic;
--signal  r_valid	: std_logic;
   signal s_full, s_empty, r_out0 : std_logic;
   signal s_A_gre_B, s_A_gre_MOV, s_B_gre_MOV : std_logic;
   signal s_adr_mode : std_logic_vector (1 downto 0);
   signal r_push : std_logic;
   
begin   
   
--**************************************************************************--
-- RAM instances
------------------------------------------------------------------------------
G1: for I in 0 to 1 generate

  KEY_DPRAM : generic_dpram
    generic map(
      -- standard parameters
      g_data_width               => t_key'length,
      g_size                     => c_elements,
      g_with_byte_enable         => false,
      --g_addr_conflict_resolution => "dont_care",
      g_init_file                => "",
      g_dual_clock               => false
      )
    port map(
      rst_n_i => rst_n_i,
      -- Port A
      clka_i  => clk_sys_i,
      wea_i   => '0',
      aa_i    => s_aa(I),
      da_i    => (others => '0'),
      qa_o    => s_qa(I),
      -- Port B
      clkb_i  => clk_sys_i,
      web_i   => we_i,
      ab_i    => wr_idx_i,
      db_i    => wr_key_i,
      qb_o    => open
      );
      
end generate;
------------------------------------------------------------------------------


--**************************************************************************--
-- Combinatorial Logic
------------------------------------------------------------------------------

-- comparators
   s_A_gre_B      <= '1' when ( (s_qa(0) >= s_qa(1)) and f_get_r_child(r_ptr) <= r_new_last)
                else '0';
   
   s_A_gre_MOV    <= '1' when s_qa(0) >= r_mov
                else '0';
   
   s_B_gre_MOV    <= '1' when ( (s_qa(1) >= r_mov) and f_get_r_child(r_ptr) <= r_new_last)
                else '0';
                  
                  
   
   s_full         <= '1' when r_last = to_unsigned(c_elements-1, r_last'length)
                else '0';
   
   s_empty        <= '1' when r_last = 0
                else '0';

-- downward search & adresses
   s_ptr_down <= c_first              when r_state = e_HEAP_DOWN_SETUP
       else f_get_l_child(r_ptr) when (s_A_gre_B = '0' and s_A_gre_mov = '0')
       else f_get_r_child(r_ptr) when (s_A_gre_B = '1' and s_B_gre_mov = '0')
       else r_ptr;

   s_adr_down(0) <=  std_logic_vector(f_get_l_child(s_ptr_down));
   s_adr_down(1) <=  std_logic_vector(f_get_r_child(s_ptr_down));
      
   s_parent_le_children <= '1' when ( (s_B_gre_mov = '1' or f_get_r_child(r_ptr) > r_new_last) and (s_A_gre_mov = '1' or f_get_l_child(r_ptr) > r_new_last)) and r_state = e_HEAP_DOWN
            else '0';
               
   s_lowest_level <= '1' when f_is_lowest_level(r_ptr, r_new_last) and r_state = e_HEAP_DOWN
             else '0';
      
-- upward search & adresses      
   s_ptr_up <= r_last          when r_state = e_HEAP_UP_SETUP
       else f_get_parent(r_ptr)  when (s_A_gre_mov = '1')
       else r_ptr;
      
   s_adr_up(0) <=  std_logic_vector(f_get_parent(s_ptr_up));
      
   s_child_gre_parent <= '1' when (s_A_gre_mov = '0') and r_state = e_HEAP_UP
            else '0';
               
   s_highest_level <= '1' when s_ptr_up = c_first and r_state = e_HEAP_UP
             else '0';
   
-- indicices valid and final position flags
   s_pos_found <= (s_parent_le_children or s_lowest_level) or (s_child_gre_parent or s_highest_level);
   s_valid     <= '1' when r_state = e_HEAP_DOWN or r_state = e_HEAP_UP
             else '0';
                     
-- default addresses
   s_adr_def(0) <= std_logic_vector(c_first);
   s_adr_def(1) <= std_logic_vector(r_last);

-- RAM addressing
   mux_adr_all : with s_adr_mode select
      s_aa <= s_adr_down   when c_DOWN,
              s_adr_up     when c_UP,
              s_adr_def    when others; 
   
   -- outputs
   idx_o    <= std_logic_vector(r_ptr); 
   valid_o  <= s_valid;
   final_o  <= s_pos_found;
   last_o   <= std_logic_vector(r_last);
   empty_o  <= s_empty;
   full_o   <= s_full;
------------------------------------------------------------------------------


--**************************************************************************--
-- Registers / Pipeline
------------------------------------------------------------------------------   
   pipeline: process(clk_sys_i)
   begin
    if(rising_edge(clk_sys_i)) then
      if(rst_n_i = '0') then
       
      else
         --r_lowest_level       <= s_lowest_level;
         --r_parent_le_children <= s_parent_le_children; 
        
         --r_highest_level      <= s_highest_level;
         --r_child_gre_parent   <= s_child_gre_parent;
         
         --r_valid              <= s_valid;
         r_pos_found          <= s_pos_found; 
      end if;
    end if;
    end process pipeline; 
------------------------------------------------------------------------------


--**************************************************************************--
-- FSM
------------------------------------------------------------------------------     
   main: process(clk_sys_i)
      variable v_cmd    : std_logic_vector (1 downto 0);
      variable v_state  : t_op_state;
   begin
    if(rising_edge(clk_sys_i)) then
      if(rst_n_i = '0') then
         r_state     <= e_IDLE;
         r_ptr       <= (others => '0');
         r_last      <= (others => '0');
         r_mov       <= (others => '0');
         s_adr_mode  <= (others => '0');
         r_new_last  <= (others => '0');
         busy_o      <= '0';
      else
         v_cmd    := push_i & pop_i;
         v_state  := r_state;
         
         case r_state is
            when e_IDLE => r_mov <= s_qa(1); -- set moving element to last element. necessary for remove function 
                           case v_cmd is
                              when c_INSERT  => if(s_full = '0') then
                                                   r_mov       <= movkey_i;
                                                   r_ptr       <= r_last +1;
                                                   r_new_last  <= r_last +1;
                                                   v_state     := e_HEAP_UP_SETUP;  --reorganise heap upward
                                                else
                                                   -- signal error
                                                   v_state  := e_IDLE;
                                                end if;
                                                                     
                              when c_REMOVE  => if(s_empty = '0') then
                                                   -- last element is the moving one. copy to r_mov ...
                                                   r_mov       <= r_mov;
                                                   -- update pointers
                                                   r_new_last  <= r_last -1;
                                                   r_ptr       <= c_first;
                                                   
                                                   if(r_last = c_first) then
                                                      --we just emptied the heap
                                                      --no reorganising, just update pointers
                                                      v_state  := e_UPDATE; 
                                                   else
                                                      v_state  := e_HEAP_DOWN_SETUP;   --reorganise heap downward
                                                   end if;
                                                else
                                                   -- signal error
                                                   v_state  := e_IDLE;  
                                                end if;  
                                          
                              when c_REPLACE => r_mov       <= movkey_i;
                                                r_new_last  <= r_last;
                                                r_ptr       <= c_first;       --update pointers
                                                v_state     := e_HEAP_DOWN_SETUP;        --reorganise heap
                                                                                                                        
                              when others    => null;
                           end case;
                           
            
            when e_HEAP_UP_SETUP    => r_last   <= r_new_last;
                                       v_state  := e_HEAP_UP;
            
            when e_HEAP_DOWN_SETUP  => v_state  := e_HEAP_DOWN;
                    
            when e_HEAP_DOWN        => r_ptr    <= s_ptr_down;
                                       if(s_pos_found = '1') then
                                          v_state  := e_UPDATE;
                                       else
                                          v_state  := e_HEAP_DOWN; 
                                       end if;
                           
            when e_HEAP_UP          => r_ptr   <= s_ptr_up;
                                       if(r_pos_found = '1') then
                                          v_state  := e_UPDATE;
                                       else
                                          v_state  := e_HEAP_UP; 
                                       end if;
                  
            when e_UPDATE           => r_last   <= r_new_last;
                                       v_state  := e_IDLE;
                                 
            when others             => v_state  := e_IDLE;                   
                                 
         end case;  
         
         case v_state is
            when e_HEAP_DOWN_SETUP  => s_adr_mode <= c_DOWN;   
            when e_HEAP_DOWN        => s_adr_mode <= c_DOWN; 
            when e_HEAP_UP_SETUP    => s_adr_mode <= c_UP;    
            when e_HEAP_UP          => s_adr_mode <= c_UP;  
            when others             => s_adr_mode <= c_DEF;                    
         end case;
         
         if(v_state = e_IDLE) then
            busy_o     <= '0';
         else
            busy_o     <= '1';
         end if;   
            
         r_state <= v_state;     
         
      end if;
    end if;
   end process main;
------------------------------------------------------------------------------
           
end behavioral;      
      
      
