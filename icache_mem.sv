module icache_mem(
    input clock,
    input reset, 
    input [31:0] pc, 
    input write_enable,
    input [31:0] write_addr,
    input [63:0] write_data,
    input [31:0] prefetch_pc_check,

    output logic [1:0][31:0] instr,
    output logic [1:0]       num_valid_instr,
    output logic             prefeetch_pc_is_in_cache
);

//calculates the pc of second superscalar instr
logic [31:0] second_pc;
assign second_pc = pc + 4;

//temp values
logic pc_1_block_offset, pc_2_block_offset; //prefetch_block_offset;
logic [4:0] pc_1_set, pc_2_set, prefetch_set;
logic [23:0] pc_1_tag, pc_2_tag, prefetch_tag;

assign pc_1_block_offset = pc[2];
assign pc_2_block_offset = second_pc[2];

assign pc_1_set = pc[7:3];
assign pc_2_set = second_pc[7:3];
assign prefetch_set = prefetch_pc_check[7:3];

assign pc_1_tag = pc[31:8];
assign pc_2_tag = second_pc[31:8];
assign prefetch_tag = prefetch_pc_check[31:8];


logic [1:0][31:0] data[31:0];
logic [1:0][31:0] ras_push;
logic [1:0][31:0] ras_pop;
logic [31:0][23:0] tags;
logic [31:0] valid_entry_bits; //one per tag/set


//CAM for tag in correct set
logic [1:0] cache_hit_bits;

always_comb begin 
    instr = {32'b0, 32'b0};
    cache_hit_bits = 2'b0;
    prefetch_pc_is_in_cache = 1'b0;

    if((pc_1_tag == tags[pc_1_set]) & valid_entry_bits[pc_1_set]) begin 
        cache_hit_bits[1] = 1;
        instr[1] = data[pc_1_set][pc_1_block_offset];
    end 

    if(pc_2_tag == tags[pc_2_set]) & valid_entry_bits[pc_2_set]) begin 
        cache_hit_bits[0] = 1;
        instr[0] = data[pc_2_set][pc_2_block_offset];
    end

    if((prefetch_tag == tags[prefetch_set]) & valid_entry_bits[prefetch_set]) begin 
        prefetch_pc_is_in_cache = 1'b1;
    end 
end

assign num_valid_instr = (!cache_hit_bits[1])? 2'b00 : (!cache_hit_bits[0])? 2'b01 : 2'b10;

//write operation 

logic [4:0] write_set; 
logic [23:0] write_tag;
assign write_set = write_addr[7:3];
assign write_tag = write_addr[31:8];

logic inst1_pop, inst1_push, inst0_pop, inst0_push;
logic [6:0] inst1_opcode, inst0_opcode;
assign inst1_opcode = write_data[38:32];
assign inst0_opcode = write_data[6:0];

logic inst1_rd_link, inst0_rd_link, inst1_rs_link, inst0_rs_link;
assign inst0_rd_link = (write_data[11:7] == 5'd1) | (write_data[11:7] == 5'd5);
assign inst0_rs_link = (write_data[19:15] == 5'd1) | (write_data[19:15] == 5'd5);
assign inst1_rs_link = (write_data[43:39] == 5'd1) | (write_data[43:39] == 5'd5);
assign inst1_rs_link = (write_data[51:47] == 5'd1) | (write_data[51:47] == 5'd5);

//calculate push or pop bits

always_comb begin
    //JAL 
    if(inst0_opcode == `RV32_JAL_OP) begin 
        inst0_pop = 0; 
        inst0_push = isnt0_rd_link;
    end 
    //JALR table
    else if(inst0_rd_link & !inst0_rs_link) begin 
        if(!inst0_rd_link & inst0_rs_link) begin
            inst0_pop = 1; 
            isnt0_push = 0;
        end 
        else if(inst0_rd_link & !inst0_rs_link) begin 
            inst0_pop = 0;
            inst0_push = 1;
        end
        else if(inst0_rd_link & inst0_rs_link) begin 
            inst0_push = 1;
            inst0_pop = (write_data[19:15] != write_data[11:7]);
        end 
        else begin 
            inst0_pop = 0; 
            inst0_push = 0;
        end 
    end

    else begin 
        inst0_push = 0; 
        inst0_pop = 0; 
    end

    //JAL
    if(inst1_opcodde == `RV32_JAL_OP) begin 
        inst1_pop = 0;
        inst1_push = inst1_rd_link;
    end 
    //JALR 
    else if(inst1_opcode == `RV32_JALR_OP) begin
        if(!inst_rd_link & inst1_rs_link) begin 
            inst1_pop = 1; 
            inst1_push = 0;
        end 
        else if(inst1_rd_link & !inst_rs_link) begin 
            inst1_pop = 0; 
            inst1_push = 1;
        end 
        else if(inst1_rd_link & inst1_rs_link) begin 
            inst1_push = 1;
            inst1_pop = (write_data[51:47 != write_data[43:39]]);
        end 
        else begin 
            inst1_pop = 0; 
            inst1_push = 0;
        end 
    end 

    else begin 
        inst1_push = 0; 
        inst1_pop = 0;
    end 
end

//


always_ff @(posedge clock) begin 
    if(reset) begin 
        tags <= `SD 0; 
        valid_entry_bits <= `SD 0; 
    end 
    else if(write_enable) begin 
        data[write_set][0] <= `SD write_data[31:0];
        data[write_set][1] <= `SD write_data[63:32];
        tags[write_set]    <= `SD write_tag;
        valid_entry_bits[write_set] <= `SD 1;
        ras_push[write_set][1] <= `SD inst1_push;
        ras_push[write_set][0] <= `SD inst0_push;
        ras_pop[write_set][1]  <= `SD inst1_pop;
        ras_pop[write_set][0]  <= `SD inst0_pop;
    end 
end 


endmodule 

