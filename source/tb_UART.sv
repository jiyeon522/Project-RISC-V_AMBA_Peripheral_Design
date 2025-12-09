`timescale 1ns / 1ps

interface uart_interface;
    logic       clk;
    logic       rst;
    logic       rx;
    logic       tx;
    logic [7:0] expected_data; 
    logic [3:0] PADDR;
    logic [31:0] PWDATA;
    logic       PWRITE;
    logic       PENABLE;
    logic       PSEL;
    logic [31:0] PRDATA;
    logic       PREADY;
endinterface

class transaction;
    bit [7:0]   uart_send_data; 
    bit [7:0]   uart_received_data;
    bit         rx;
    bit         tx;
    
endclass

class generator;
    transaction       trans;
    mailbox #(transaction) gen2drv_mbox;
    event             gen_next_event;
    int               transaction_count = 0;
    
    bit [7:0] unique_data_queue[$];

    function new(mailbox#(transaction) gen2drv_mbox, event gen_next_event);
        this.gen2drv_mbox   = gen2drv_mbox;
        this.gen_next_event = gen_next_event;
        initialize_queue();
    endfunction

    function void initialize_queue();
        bit [7:0] all_values[256];
        foreach (all_values[i]) begin
            all_values[i] = i;
        end
        all_values.shuffle();
        foreach (all_values[i]) begin
            unique_data_queue.push_back(all_values[i]);
        end
        $display("[GEN] Initialized and shuffled 256 unique values.");
    endfunction

    task run(int run_count);
        if (run_count > unique_data_queue.size()) begin
            $fatal("[GEN] Error: Requested %0d transactions, but only %0d unique values are available.",
                   run_count, unique_data_queue.size());
        end

        repeat (run_count) begin
            transaction_count++;
            $display("=================%0d transaction=============", transaction_count); 
            trans = new();
            
            trans.uart_send_data = unique_data_queue.pop_front();
            
            gen2drv_mbox.put(trans);
            $display("[GEN] Sending unique data: 0x%h", trans.uart_send_data); 
            @gen_next_event;
        end
    endtask
endclass

class driver;
    transaction       trans;
    mailbox #(transaction) gen2drv_mbox;
    event             drv2mon_event;
    virtual uart_interface uart_intf;

    parameter CLOCK_PERIOD_NS = 10;
    parameter BITPERCLOCK     = 10416;
    parameter BIT_PERIOD      = BITPERCLOCK * CLOCK_PERIOD_NS;

    localparam logic [3:0] SIGNAL_REG_ADDR = 4'h0;
    localparam logic [3:0] WDATA_REG_ADDR  = 4'h4;
    localparam logic [3:0] RDATA_REG_ADDR  = 4'h8;

    localparam int TX_FULL_BIT  = 1; 
    localparam int RX_EMPTY_BIT = 0; 

    function new(mailbox#(transaction) gen2drv_mbox,
                 virtual uart_interface uart_intf,
                 event drv2mon_event);
        this.gen2drv_mbox  = gen2drv_mbox;
        this.uart_intf     = uart_intf;
        this.drv2mon_event = drv2mon_event;
    endfunction

    function string get_apb_state();
        return $sformatf("ADDRESS:%h WRITE:%b ENABLE:%b SEL:%b WDATA:%08h RDATA:%08h READY:%b",
                         uart_intf.PADDR, uart_intf.PWRITE, uart_intf.PENABLE,
                         uart_intf.PSEL, uart_intf.PWDATA, uart_intf.PRDATA,
                         uart_intf.PREADY);
    endfunction

    task reset();
        uart_intf.clk = 0;
        uart_intf.rst = 1;
        uart_intf.rx  = 1;
        uart_intf.tx  = 1;
        repeat (2) @(posedge uart_intf.clk);
        uart_intf.rst = 0;
        @(posedge uart_intf.clk);
        $display("[DRV] Reset asserted");
    endtask

    task uart_sender(bit [7:0] uart_send_data);
        uart_intf.rx = 0;
        #(BIT_PERIOD);
        for (int i = 0; i < 8; i = i + 1) begin
            uart_intf.rx = uart_send_data[i];
            #(BIT_PERIOD);
        end
        uart_intf.rx = 1;
        #(BIT_PERIOD);
    endtask

    task uart_apb_read(input logic [3:0] addr, output logic [31:0] data);
        logic [31:0] read_value;
        @(posedge uart_intf.clk);
        uart_intf.PADDR   = addr;
        uart_intf.PWRITE  = 0;
        uart_intf.PSEL    = 1;
        uart_intf.PENABLE = 0;
        @(posedge uart_intf.clk);
        uart_intf.PENABLE = 1;
        wait (uart_intf.PREADY == 1);
        read_value = uart_intf.PRDATA;
        $display("%s", get_apb_state());
        @(posedge uart_intf.clk);
        uart_intf.PSEL    = 0;
        uart_intf.PENABLE = 0;
        data            = read_value;
    endtask

    task uart_apb_write(input logic [3:0] addr, input logic [31:0] data);
        @(posedge uart_intf.clk);
        uart_intf.PADDR   = addr;
        uart_intf.PWDATA  = data;
        uart_intf.PWRITE  = 1;
        uart_intf.PSEL    = 1;
        uart_intf.PENABLE = 0;
        @(posedge uart_intf.clk);
        uart_intf.PENABLE = 1;
        wait (uart_intf.PREADY == 1);
        $display("%s", get_apb_state());
        @(posedge uart_intf.clk);
        uart_intf.PSEL    = 0;
        uart_intf.PENABLE = 0;
    endtask

    task run();
        logic [31:0] read_data;
        forever begin
            
            gen2drv_mbox.get(trans);
            uart_intf.expected_data = trans.uart_send_data;
            uart_sender(trans.uart_send_data);
            
            $display("[DRV] Sent 0x%h to RX.", trans.uart_send_data);
            
            $display("[DRV-APB] Check RX FIFO for Data (rx_empty=0).");
            begin
                logic [31:0] current_status;
                do begin
                    uart_apb_read(SIGNAL_REG_ADDR, current_status);
                end while (current_status[RX_EMPTY_BIT] == 1); 
            end
            uart_apb_read(RDATA_REG_ADDR, read_data);
            
            $display("[DRV-APB] Read 0x%h from RX FIFO.", read_data[7:0]);
            
            $display("[DRV-APB] Check TX FIFO is not full (tx_full=0).");
            begin
                logic [31:0] current_status;
                do begin
                    uart_apb_read(SIGNAL_REG_ADDR, current_status);
                end while (current_status[TX_FULL_BIT] == 1); 
            end
            uart_apb_write(WDATA_REG_ADDR, read_data);
            
            $display("[DRV-APB] Wrote 0x%h to TX FIFO.",
                           read_data[7:0]);
            ->drv2mon_event;
        end
    endtask
endclass

class monitor;
    mailbox #(transaction) mon2scb_mbox;
    event             drv2mon_event;
    virtual uart_interface uart_intf;

    parameter CLOCK_PERIOD_NS = 10;
    parameter BITPERCLOCK     = 10416;
    parameter BIT_PERIOD      = BITPERCLOCK * CLOCK_PERIOD_NS;

    function new(mailbox#(transaction) mon2scb_mbox,
                 virtual uart_interface uart_intf,
                 event drv2mon_event);
        this.mon2scb_mbox  = mon2scb_mbox;
        this.uart_intf     = uart_intf;
        this.drv2mon_event = drv2mon_event;
    endfunction

    task run();
        localparam bit VERBOSE_DEBUG = 1;
        forever begin
            transaction mon_trans; 
            @(drv2mon_event);
            mon_trans = new();
            mon_trans.uart_send_data = uart_intf.expected_data;

            wait (uart_intf.tx == 0);
            #(BIT_PERIOD + BIT_PERIOD / 2);
            mon_trans.uart_received_data[0] = uart_intf.tx;
            for (int i = 1; i < 8; i = i + 1) begin
                #(BIT_PERIOD);
                mon_trans.uart_received_data[i] = uart_intf.tx;
            end
            #(BIT_PERIOD / 2);
            if (VERBOSE_DEBUG) begin
                $display("[MON] Received TX Data: 0x%h (Expected: 0x%h)", 
                         mon_trans.uart_received_data, mon_trans.uart_send_data);
            end
            @(posedge uart_intf.clk);
            mon2scb_mbox.put(mon_trans); 
        end
    endtask
endclass

class scoreboard;
    transaction       trans;
    mailbox #(transaction) mon2scb_mbox;
    event             gen_next_event;

    int pass_unique_count = 0;
    int data_fail_count = 0;
    int duplicate_fail_count = 0;
    int total_transaction_count = 0;
    
    bit seen_values[bit [7:0]]; 

    function new(mailbox#(transaction) mon2scb_mbox, event gen_next_event);
        this.mon2scb_mbox   = mon2scb_mbox;
        this.gen_next_event = gen_next_event;
    endfunction

    task run();
        forever begin
            mon2scb_mbox.get(trans);
            total_transaction_count++;
            
            if (trans.uart_send_data == trans.uart_received_data) begin
                if (seen_values.exists(trans.uart_received_data)) begin
                    $display("[SCR] DUPLICATE FAIL - Expected: 0x%h, Received: 0x%h (Already seen)",
                             trans.uart_send_data, trans.uart_received_data);
                    duplicate_fail_count = duplicate_fail_count + 1;
                end else begin
                    $display("[SCR] PASS - Expected: 0x%h, Received: 0x%h (Unique)",
                             trans.uart_send_data, trans.uart_received_data);
                    pass_unique_count = pass_unique_count + 1;
                    seen_values[trans.uart_received_data] = 1;
                end
            end else begin
                $display("[SCR] DATA FAIL - Expected: 0x%h, Received: 0x%h",
                         trans.uart_send_data, trans.uart_received_data);
                data_fail_count = data_fail_count + 1;
            end
            ->gen_next_event;
        end
    endtask

    task report();
        int total_failures = data_fail_count + duplicate_fail_count;
        real pass_rate   = 0.0;
        string final_status = (total_failures == 0) ? "PASS" : "FAIL";
        
        if (total_transaction_count > 0) begin
            pass_rate = (pass_unique_count * 100.0) / total_transaction_count;
        end

        $display("/////////////////////////////////////////////////////////////");
        $display("/////////////////   UART TESTBENCH REPORT   /////////////////");
        $display("/////////////////////////////////////////////////////////////");
        $display("");
        $display("-------------   TEST SUMMARY   -------------");
        $display("   %-25s : %s", "FINAL STATUS", final_status);
        $display("   %-25s : %0.2f %%", "Pass Rate", pass_rate);
        $display("");
        $display("-------------   COUNT BREAKDOWN   -------------");
        $display("   %-25s : %0d", "Total Transactions", total_transaction_count);
        $display("   %-25s : %0d", "Passed (Unique)", pass_unique_count);
        $display("   %-25s : %0d", "Failed (Data Mismatch)", data_fail_count);
        $display("   %-25s : %0d", "Failed (Duplicate Data)", duplicate_fail_count);
        $display("   %-25s : %0d", "Total Failures", total_failures);
        $display("");
        $display("-------------   UNIQUENESS CHECK   -------------");
        $display("   %-25s : %0d / 256", "Unique Values Seen", seen_values.num());
        if (seen_values.num() != 256 && total_transaction_count == 256 && total_failures == 0) begin
            $display("   WARNING: All 256 transactions passed, but not all unique values were seen.");
        end
        $display("/////////////////////////////////////////////////////////////");
    endtask
endclass

class environment;
    transaction       trans;
    mailbox #(transaction) gen2drv_mbox;
    mailbox #(transaction) mon2scb_mbox;
    event gen_next_event;
    event drv2mon_event;
    generator gen;
    driver    drv;
    monitor   mon;
    scoreboard scb;
    virtual uart_interface uart_intf;

    function new(virtual uart_interface uart_intf);
        this.uart_intf = uart_intf;
        gen2drv_mbox = new();
        mon2scb_mbox = new();
        gen = new(gen2drv_mbox, gen_next_event);
        drv = new(gen2drv_mbox, uart_intf, drv2mon_event);
        mon = new(mon2scb_mbox, uart_intf, drv2mon_event);
        scb = new(mon2scb_mbox, gen_next_event);
    endfunction

    task reset();
        drv.reset();
        uart_intf.PADDR   <= 4'bx;
        uart_intf.PWDATA  <= 32'bx;
        uart_intf.PWRITE  <= 1'b0;
        uart_intf.PENABLE <= 1'b0;
        uart_intf.PSEL    <= 1'b0;
        uart_intf.expected_data <= 8'bx; 
        @(posedge uart_intf.clk);
    endtask

    task run();
        fork
            drv.run();
            mon.run();
            scb.run();
        join_none 

        gen.run(256);

        #100ns; 

        scb.report();
        $stop;
    endtask
endclass

module tb_UART ();
    uart_interface uart_interface_tb ();
    environment    env;

    UART_Periph dut (
        .PCLK(uart_interface_tb.clk),
        .PRESET(uart_interface_tb.rst),
        .PADDR(uart_interface_tb.PADDR),
        .PWDATA(uart_interface_tb.PWDATA),
        .PWRITE(uart_interface_tb.PWRITE),
        .PENABLE(uart_interface_tb.PENABLE),
        .PSEL(uart_interface_tb.PSEL),
        .PRDATA(uart_interface_tb.PRDATA),
        .PREADY(uart_interface_tb.PREADY),
        .rx(uart_interface_tb.rx),
        .tx(uart_interface_tb.tx)
    );

    always #5 uart_interface_tb.clk = ~uart_interface_tb.clk;

    initial begin
        uart_interface_tb.clk = 0;
        env = new(uart_interface_tb);
        env.reset();
        env.run();
    end
endmodule
