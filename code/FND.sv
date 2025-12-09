`timescale 1ns / 1ps
module FND_Periph (
    input  logic       PCLK,
    input  logic       PRESET,
    input  logic [4:0] PADDR,
    input  logic       PSEL,
    input  logic       PENABLE,
    input  logic       PWRITE,
    input  logic [31:0] PWDATA,
    output logic [31:0] PRDATA,
    output logic       PREADY,
    output logic [3:0] FND_comm,
    output logic [7:0] FND_font
);

    logic [31:0] slv_reg0, slv_reg1;
    
    logic FCR;
    logic [15:0] FDR;

    assign FCR = slv_reg0[0];
    assign FDR = slv_reg1[15:0];

    always_ff @(posedge PCLK or posedge PRESET) begin
        if (PRESET) begin
            slv_reg0 <= 0;
            slv_reg1 <= 0;
        end else begin
            PREADY <= 1'b0; 
            if (PSEL && PENABLE) begin
                PREADY <= 1'b1;
                if (PWRITE) begin
                    case (PADDR[4:2])
                        3'd0 : slv_reg0 <= PWDATA;
                        3'd1 : slv_reg1 <= PWDATA;
                        default: ;
                    endcase
                end 
            end
        end
    end

    always_comb begin
        PRDATA = 32'b0; 
        if (PSEL && PENABLE && !PWRITE) begin
            case (PADDR[4:2])
                3'd0: PRDATA = slv_reg0;
                3'd1: PRDATA = slv_reg1;
                default: PRDATA = 32'b0;
            endcase
        end
    end

    parameter CLK_DIV = 50000;
    logic o_clk;
    reg [15:0] r_count;
    reg r_clk;

    always @(posedge PCLK or posedge PRESET) begin
        if (PRESET) begin
            r_count <= 0;
            r_clk  <= 1'b0;
        end else begin
            if (r_count == CLK_DIV - 1) begin
                r_count <= 0;
                r_clk  <= ~r_clk;
            end else begin
                r_count <= r_count + 1;
            end
        end
    end
    assign o_clk = r_clk;

    logic [1:0] seg_sel; 
    
    always @(posedge o_clk or posedge PRESET) begin
        if (PRESET) seg_sel <= 0;
        else seg_sel <= seg_sel + 1;
    end

    logic [3:0] current_digit_data; 
    
    always_comb begin
        case (seg_sel)
            2'b00: current_digit_data = FDR[3:0]; 
            2'b01: current_digit_data = FDR[7:4]; 
            2'b10: current_digit_data = FDR[11:8];
            2'b11: current_digit_data = FDR[15:12];
            default: current_digit_data = 4'b0000; 
        endcase
    end

    always_comb begin
        case (seg_sel)
            2'b00: FND_comm = FCR ? 4'b1110 : 4'b1111;
            2'b01: FND_comm = FCR ? 4'b1101 : 4'b1111;
            2'b10: FND_comm = FCR ? 4'b1011 : 4'b1111;
            2'b11: FND_comm = FCR ? 4'b0111 : 4'b1111;
            default: FND_comm = 4'b1111;
        endcase
    end

    logic [7:0] segment_pattern; 
    
    always_comb begin
        case (current_digit_data) 
            4'd0:  segment_pattern = 8'b11000000; // '0'
            4'd1:  segment_pattern = 8'b11111001; // '1'
            4'd2:  segment_pattern = 8'b10100100; // '2'
            4'd3:  segment_pattern = 8'b10110000; // '3'
            4'd4:  segment_pattern = 8'b10011001; // '4'
            4'd5:  segment_pattern = 8'b10010010; // '5'
            4'd6:  segment_pattern = 8'b10000010; // '6'
            4'd7:  segment_pattern = 8'b11111000; // '7'
            4'd8:  segment_pattern = 8'b10000000; // '8'
            4'd9:  segment_pattern = 8'b10010000; // '9'
            4'd10: segment_pattern = 8'b10010010; // 'S'
            4'd11: segment_pattern = 8'b10000111; // 'T'
            4'd12: segment_pattern = 8'b11000000; // 'O'
            4'd13: segment_pattern = 8'b10001100; // 'P'
            default: segment_pattern = 8'b11111111; // Off
        endcase
    end

    assign FND_font = segment_pattern; 

endmodule

