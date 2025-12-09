`timescale 1ns / 1ps


module UART_Periph (
    input  logic       PCLK,
    input  logic       PRESET,
    input  logic [3:0] PADDR,
    input  logic       PWRITE,
    input  logic       PENABLE,
    input  logic [31:0] PWDATA,
    input  logic       PSEL,
    output logic [31:0] PRDATA,
    output logic       PREADY,
    input  logic       rx,
    output logic       tx
);


    logic [3:0] w_uart_status;
    logic [7:0] w_uart_tx_data;
    logic [7:0] w_uart_rx_data;
    logic       w_uart_tx_en;
    logic       w_uart_rx_en;


    APB_SlaveIntf_UART U_UART_Intf (
        .*,
        .uart_status_in(w_uart_status),
        .uart_tx_data_out(w_uart_tx_data),
        .uart_rx_data_in(w_uart_rx_data),
        .uart_tx_write_en(w_uart_tx_en),
        .uart_rx_read_en(w_uart_rx_en)
    );


    UART U_UART (
        .clk(PCLK),
        .rst(PRESET),
        .rx(rx),
        .tx(tx),
        .USTATEREG(w_uart_status),
        .UWDATA(w_uart_tx_data),
        .URDATA(w_uart_rx_data),
        .we_tx(w_uart_tx_en),
        .re_rx(w_uart_rx_en)
    );



endmodule


module APB_SlaveIntf_UART (
    input  logic       PCLK,
    input  logic       PRESET,
    input  logic [3:0] PADDR,
    input  logic       PWRITE,
    input  logic       PENABLE,
    input  logic [31:0] PWDATA,
    input  logic       PSEL,
    output logic [31:0] PRDATA,
    output logic       PREADY,
    input  logic [3:0] uart_status_in,
    output logic [7:0] uart_tx_data_out,
    input  logic [7:0] uart_rx_data_in,
    output logic       uart_tx_write_en,
    output logic       uart_rx_read_en
);

    logic [31:0] status_reg;
    logic [31:0] tx_data_reg;
    logic [31:0] rx_data_reg;
    logic [31:0] tx_data_next;

    logic        tx_write_strobe, tx_write_strobe_next;
    logic        rx_read_strobe, rx_read_strobe_next;
    logic [31:0] read_data_out, read_data_out_next;
    logic        ready_out, ready_out_next;

    assign uart_tx_write_en = tx_write_strobe;
    assign uart_rx_read_en = rx_read_strobe;

    typedef enum {
        IDLE,
        READ,
        WRITE
    } apb_state_t;

    apb_state_t current_state, next_state;

    assign status_reg[3:0] = uart_status_in;
    assign uart_tx_data_out = tx_data_reg[7:0];
    assign rx_data_reg[7:0] = uart_rx_data_in;

    assign PRDATA = read_data_out;
    assign PREADY = ready_out;

    always_ff @(posedge PCLK, posedge PRESET) begin
        if (PRESET) begin
            status_reg[31:4]   <= 0;
            tx_data_reg        <= 0;
            rx_data_reg[31:8]  <= 0;
            current_state      <= IDLE;
            tx_write_strobe    <= 1'b0;
            rx_read_strobe     <= 1'b0;
            read_data_out      <= 32'bx;
            ready_out          <= 1'b0;
        end else begin
            tx_data_reg        <= tx_data_next;
            current_state      <= next_state;
            tx_write_strobe    <= tx_write_strobe_next;
            rx_read_strobe     <= rx_read_strobe_next;
            read_data_out      <= read_data_out_next;
            ready_out          <= ready_out_next;
        end
    end

    always_comb begin
        next_state           = current_state;
        tx_data_next         = tx_data_reg;
        tx_write_strobe_next = 1'b0;
        rx_read_strobe_next  = 1'b0;
        read_data_out_next   = read_data_out;
        ready_out_next       = ready_out;

        case (current_state)
            IDLE: begin
                ready_out_next = 1'b0;
                if (PSEL && PENABLE) begin
                    if (PWRITE) begin
                        next_state = WRITE;
                        ready_out_next = 1'b1;
                        
                        case (PADDR[3:2])
                            2'd0: ;
                            2'd1: begin
                                tx_data_next = PWDATA;
                                tx_write_strobe_next = 1'b1;
                            end
                            2'd2: ;
                            2'd3: ;
                        endcase
                    end else begin
                        next_state = READ;
                        ready_out_next = 1'b1;
                        
                        case (PADDR[3:2])
                            2'd0: begin
                                read_data_out_next = status_reg;
                            end
                            2'd1: begin
                                read_data_out_next = tx_data_reg;
                            end
                            2'd2: begin
                                read_data_out_next = rx_data_reg;
                                rx_read_strobe_next = 1'b1;
                            end
                            2'd3: ;
                        endcase
                    end
                end
            end

            READ: begin
                ready_out_next = 1'b0;
                next_state = IDLE;
            end
            
            WRITE: begin
                next_state = IDLE;
                ready_out_next = 1'b0;
            end
        endcase
    end

endmodule




module UART (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx,
    output logic       tx,
    output logic [3:0] USTATEREG,
    input  logic [7:0] UWDATA,
    output logic [7:0] URDATA,
    input  logic       we_tx,
    input  logic       re_rx
);

    logic w_tick;
    logic w_rx_done;
    logic w_tx_busy;
    logic w_tx_fifo_empty;
    logic w_rx_fifo_empty;
    logic w_rx_fifo_full;
    logic w_tx_fifo_full;
    logic [7:0] w_rx_wdata, w_rx_rdata, w_tx_wdata, w_tx_rdata;

    assign USTATEREG = {
        w_rx_fifo_full, w_tx_fifo_empty, w_tx_fifo_full, w_rx_fifo_empty
    };
    assign w_tx_wdata = UWDATA;
    assign URDATA = w_rx_rdata;


    baud_tick_gen U_BAUD_TICK_GEN (
        .rst (rst),
        .clk (clk),
        .tick(w_tick)
    );


    fifo U_UART_TX_FIFO (
        .clk(clk),
        .rst(rst),
        .wr(we_tx),
        .rd(~w_tx_busy),
        .wdata(w_tx_wdata),
        .rdata(w_tx_rdata),
        .full(w_tx_fifo_full),
        .empty(w_tx_fifo_empty)
    );
    fifo U_UART_RX_FIFO (
        .clk(clk),
        .rst(rst),
        .wr(w_rx_done),
        .rd(re_rx),
        .wdata(w_rx_wdata),
        .rdata(w_rx_rdata),
        .full(w_rx_fifo_full),
        .empty(w_rx_fifo_empty)
    );

    uart_tx U_UART_TX (
        .clk(clk),
        .rst(rst),
        .tx_start(~w_tx_fifo_empty),
        .tx_data(w_tx_rdata),
        .tick(w_tick),
        .tx_busy(w_tx_busy),
        .tx(tx)
    );


    uart_rx U_UART_RX (
        .clk(clk),
        .rst(rst),
        .tick(w_tick),
        .rx(rx),
        .rx_data(w_rx_wdata),
        .rx_done(w_rx_done)
    );


endmodule

`timescale 1ns / 1ps

module baud_tick_gen (
    input  rst,
    input  clk,
    output tick
);

    parameter BAUDRATE = 9600 * 16;
    localparam BAUD_COUNT = 100_000_000 / BAUDRATE;

    reg [$clog2(BAUD_COUNT)-1:0] counter_reg, counter_next;
    reg tick_reg, tick_next;

    assign tick = tick_reg;

    always @(posedge clk, posedge rst) begin
        if (rst) begin
            counter_reg <= 1'b0;
            tick_reg <= 1'b0;
        end else begin
            counter_reg <= counter_next;
            tick_reg <= tick_next;
        end
    end

    always @(*) begin
        counter_next = counter_reg;
        tick_next = tick_reg;
        if (counter_reg == BAUD_COUNT - 1) begin
            counter_next = 1'b0;
            tick_next = 1'b1;
        end else begin
            counter_next = counter_reg + 1;
            tick_next = 1'b0;
        end
    end


endmodule
`timescale 1ns / 1ps

module fifo (
    input  logic       clk,
    input  logic       rst,
    input  logic       wr,
    input  logic       rd,
    input  logic [7:0] wdata,
    output logic [7:0] rdata,
    output logic       full,
    output logic       empty
);

    logic [2:0] waddr;
    logic [2:0] raddr;
    logic w_en;

    assign wr_en = wr & ~full;

    register_file U_REG_FILE (
        .*,
        .wr(wr_en)
    );
    fifo_control_unit U_FIFO_CU (.*);

endmodule



module register_file #(
    parameter AWIDTH = 3
) (
    input  logic           clk,
    input  logic           wr,
    input  logic [7:0]     wdata,
    input  logic [AWIDTH-1:0] waddr,
    input  logic [AWIDTH-1:0] raddr,
    output logic [7:0]     rdata
);

    logic [7:0] ram[0:2**AWIDTH-1];
    assign rdata = ram[raddr];

    always_ff @(posedge clk) begin
        if (wr) begin
            ram[waddr] <= wdata;
        end
    end

endmodule




module fifo_control_unit #(
    parameter AWIDTH = 3
) (
    input  logic           clk,
    input  logic           rst,
    input  logic           wr,
    input  logic           rd,
    output logic [AWIDTH-1:0] waddr,
    output logic [AWIDTH-1:0] raddr,
    output logic           full,
    output logic           empty
);

    logic [AWIDTH-1:0] waddr_reg, waddr_next;
    logic [AWIDTH-1:0] raddr_reg, raddr_next;

    logic full_reg, full_next;
    logic empty_reg, empty_next;

    assign full  = full_reg;
    assign empty = empty_reg;

    assign waddr = waddr_reg;
    assign raddr = raddr_reg;

    always_ff @(posedge clk, posedge rst) begin
        if (rst) begin
            waddr_reg <= 0;
            raddr_reg <= 0;
            full_reg  <= 0;
            empty_reg <= 1'b1;
        end else begin
            waddr_reg <= waddr_next;
            raddr_reg <= raddr_next;
            full_reg  <= full_next;
            empty_reg <= empty_next;
        end
    end

    always_comb begin
        waddr_next = waddr_reg;
        raddr_next = raddr_reg;
        full_next  = full_reg;
        empty_next = empty_reg;
        case ({
            wr, rd
        })
            2'b01: begin
                if (!empty_reg) begin
                    raddr_next = raddr_reg + 1;
                    full_next  = 1'b0;
                    if (waddr_reg == raddr_next) begin
                        empty_next = 1'b1;
                    end
                end
            end
            2'b10: begin
                if (!full_reg) begin
                    waddr_next = waddr_reg + 1;
                    empty_next = 1'b0;
                    if (waddr_next == raddr_reg) begin
                        full_next = 1'b1;
                    end
                end
            end
            2'b11: begin
                if (full_reg) begin
                    raddr_next = raddr_reg + 1;
                    full_next  = 1'b0;
                end else if (empty_reg) begin
                    waddr_next = waddr_reg + 1;
                    empty_next = 1'b0;
                end else begin
                    raddr_next = raddr_reg + 1;
                    waddr_next = waddr_reg + 1;
                end
            end
        endcase
    end
endmodule
`timescale 1ns / 1ps

module uart_tx (
    input  logic       clk,
    input  logic       rst,
    input  logic       tx_start,
    input  logic [7:0] tx_data,
    input  logic       tick,
    output logic       tx_busy,
    output logic       tx
);

    localparam [1:0] IDLE = 2'b00, TX_START = 2'b01, TX_DATA = 2'b10, TX_STOP = 2'b11;

    logic [1:0] c_state, n_state;
    logic [2:0] bit_cnt_reg, bit_cnt_next;
    logic [3:0] tick_cnt_reg, tick_cnt_next;
    logic [7:0] data_buf_reg, data_buf_next;
    logic tx_reg, tx_next;
    logic tx_busy_reg, tx_busy_next;

    assign tx_busy = tx_busy_reg;
    assign tx = tx_reg;

    always @(posedge clk, posedge rst) begin
        if (rst) begin
            c_state      <= IDLE;
            bit_cnt_reg  <= 3'b000;
            tick_cnt_reg <= 4'b0000;
            data_buf_reg <= 8'h00;
            tx_reg       <= 1'b1;
            tx_busy_reg  <= 1'b0;
        end else begin
            c_state      <= n_state;
            bit_cnt_reg  <= bit_cnt_next;
            tick_cnt_reg <= tick_cnt_next;
            data_buf_reg <= data_buf_next;
            tx_reg       <= tx_next;
            tx_busy_reg  <= tx_busy_next;
        end
    end

    always @(*) begin
        n_state       = c_state;
        bit_cnt_next  = bit_cnt_reg;
        tick_cnt_next = tick_cnt_reg;
        data_buf_next = data_buf_reg;
        tx_next       = tx_reg;
        tx_busy_next  = tx_busy_reg;
        case (c_state)
            IDLE: begin
                tx_next = 1'b1;
                tx_busy_next = 1'b0;
                if (tx_start) begin
                    tick_cnt_next = 0;
                    data_buf_next = tx_data;
                    n_state = TX_START;
                end
            end
            TX_START: begin
                tx_next = 1'b0;
                tx_busy_next = 1'b1;
                if (tick) begin
                    if (tick_cnt_reg == 15) begin
                        tick_cnt_next = 0;
                        bit_cnt_next = 0;
                        n_state = TX_DATA;
                    end else begin
                        tick_cnt_next = tick_cnt_reg + 1;
                    end
                end
            end
            TX_DATA: begin
                tx_next = data_buf_reg[0];
                if (tick) begin
                    if (tick_cnt_reg == 15) begin
                        if (bit_cnt_reg == 7) begin
                            tick_cnt_next = 0;
                            n_state = TX_STOP;
                        end else begin
                            tick_cnt_next = 0;
                            bit_cnt_next  = bit_cnt_reg + 1;
                            data_buf_next = data_buf_reg >> 1;
                        end
                    end else begin
                        tick_cnt_next = tick_cnt_reg + 1;
                    end
                end
            end
            TX_STOP: begin
                tx_next = 1'b1;
                if (tick) begin
                    if (tick_cnt_reg == 15) begin
                        tx_busy_next = 1'b0;
                        n_state = IDLE;
                    end else begin
                        tick_cnt_next = tick_cnt_reg + 1;
                    end
                end
            end
        endcase
    end




endmodule


`timescale 1ns / 1ps

module uart_rx (
    input  logic       clk,
    input  logic       rst,
    input  logic       tick,
    input  logic       rx,
    output logic [7:0] rx_data,
    output logic       rx_done
);

    parameter [1:0] IDLE = 0, START = 1, DATA = 2, STOP = 3;
    logic [1:0] c_state, n_state;

    logic [4:0] tick_cnt_reg, tick_cnt_next;
    logic [2:0] bit_cnt_reg, bit_cnt_next;

    logic rx_done_reg, rx_done_next;
    logic [7:0] rx_buf_reg, rx_buf_next;

    assign rx_data = rx_buf_reg;
    assign rx_done = rx_done_reg;

    always @(posedge clk, posedge rst) begin
        if (rst) begin
            c_state <= IDLE;
            tick_cnt_reg <= 0;
            bit_cnt_reg <= 0;
            rx_done_reg <= 0;
            rx_buf_reg <= 0;
        end else begin
            c_state <= n_state;
            tick_cnt_reg <= tick_cnt_next;
            bit_cnt_reg <= bit_cnt_next;
            rx_done_reg <= rx_done_next;
            rx_buf_reg <= rx_buf_next;
        end
    end


    always @(*) begin
        n_state = c_state;
        tick_cnt_next = tick_cnt_reg;
        bit_cnt_next = bit_cnt_reg;
        rx_done_next = rx_done_reg;
        rx_buf_next = rx_buf_reg;

        case (c_state)
            IDLE: begin
                rx_done_next = 1'b0;
                if (!rx) begin
                    tick_cnt_next = 0;
                    n_state = START;
                end
            end

            START: begin
                if (tick) begin
                    if (tick_cnt_reg == 23) begin
                        tick_cnt_next = 0;
                        bit_cnt_next = 0;
                        n_state = DATA;
                    end else begin
                        tick_cnt_next = tick_cnt_reg + 1;
                    end
                end
            end

            DATA: begin
                if (tick) begin
                    if (tick_cnt_reg == 7) begin
                        rx_buf_next = {rx, rx_buf_reg[7:1]};
                    end

                    if (tick_cnt_reg == 15) begin
                        tick_cnt_next = 0;
                        if (bit_cnt_reg == 7) begin
                            n_state = STOP;
                        end else begin
                            bit_cnt_next = bit_cnt_reg + 1;
                        end
                    end else begin
                        tick_cnt_next = tick_cnt_reg + 1;
                    end
                end
            end

            STOP: begin
                if (tick) begin
                    if (tick_cnt_reg == 15) begin
                        rx_done_next = 1'b1;
                        n_state = IDLE;
                    end else begin
                        tick_cnt_next = tick_cnt_reg + 1;
                    end
                end
            end
            default: begin
                n_state = IDLE;
                tick_cnt_next = 0;
                bit_cnt_next = 0;
                rx_done_next = 0;
                rx_buf_next = 0;
            end
        endcase
    end


endmodule

