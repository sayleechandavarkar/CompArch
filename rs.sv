module rs_entry(
    input reset,
    input clock,
    input TAG_AND_READY [1:0] tag_1_in,
    input TAG_AND_READY [1:0] tag_2_in,
    input TAG_AND_READY [1:0] sq_deps_in,
    input IF_INST_OUT [1:0] fetched_insts_in,
    input PREG [1:0] dest_tag_in,
    input DECODE_INST_OUT [1:0] decoded_insts_in,
    input write_en,
    input write_en2,
    input CDB_PACKET [1:0] cdb_in,
    input PREG sq_ready_tag_in,
    input free_entry,
    output RS_ENTRY entry_out,
    output logic ready_out_alu,
    output logic ready_out_mult,
    output logic ready_out_mult,
    output logic ready_out_load,
    output logic ready_out__store,
    output logic avail_out
);

    assign avail_out = (entry_out.in_use == `FALSE);

    wire n_tag_1_ready = entry_out.tag_1.ready | (entry_out.tag_1.tag == cdb_in[0].tag) | (entry_out.tag_1.tag == cdb_in[1].tag);
    wire n_tag_2_ready = entry_out.tag_2.ready | (entry_out.tag_2.tag == cdb_in[0].tag) | (entry_out.tag_2.tag == cdb_in[1].tag);

    wire n_sq_dep_ready = entry_out.sq_dep.ready | (entry_out.sq_dep.tag == sq_ready_tag_in);

    //have separate ready out signals depending on which FU instruction will go to 

    wire ready = entry_out.in_use & n_tag_1_ready & n_tag_2_ready;
    assign ready_out_alu = ready & entry_out.decoded_inst.fu == ALU;
    assign ready_out_mult = ready & entry_out.decoded_inst.fu == MULTIPLIER;
    assign ready_out_load = ready & n_sq_dep_ready & entry_out.decoded_inst.fu == LOAD;
    assign ready_out_store = ready & entry_out.decoded_inst.fu == STORE;

    always_ff @(posedge clock) begin 
        if(reset | free_entry) begin 
            entry_out.tag_1 <= `SD '{6'b0,1'b0};
            entry_out.tag_2 <= `SD '{6'b0,1'b0};
            entry_out.sq_dep <= `SD '{`ZERO_PREG, `FALSE};
            entry_out.dest_tag <= `SD '{6'b0};
            entry_out.in_use <= `SD `FALSE;
            entry_out.pc <= `SD 32'd0;
            entry_out.predicted_target <= `SD 32'd0;
            entry_out.predicted_taken <= `SD `FALSE;
            entry_out.decoded_inst <= `SD '{`NOP,ALU_ADD,ALU,OPA_IS_RS1,OPB_IS_RS2,WORD,
                                            1'b0, //cond_branch
                                            1'b0, //uncond_branch
                                            1'b0, //rs1_used
                                            1'b0, //rs2_used
                                            1'b0, //has_dst
                                            1'b0, //rd_mem
                                            1'b0, //signed_rd,
                                            1'b0, //wr_mem,
                                            1'b0, //csr_op
                                            1'b0, //halt
                                            1'b0 //illegal
                                            };
            entry_out.valid <= `SD `FALSE;
        end
        else begin 
            if(write_en) begin  
                entry_out.tag_1 <= `SD tag_1_in[0];
                entry_out.tag_2 <= `SD tag_2_in[0];
                entry_out.sq_dep <= `SD sq_deps_in[0];
                entry_out.dest_tag <= `SD dest_tag_in[0];
                entry_out.in_use <= `SD `TRUE;
                entry_out.decoded_inst <= `SD decoded_insts_in[0];
                entry_out.valid <= `SD `TRUE;
                entry_out.pc <= `SD fetched_inst_in[0].pc;
                entry_out.predicted_target <= `SD fetched_insts_in[0].predicted_target;
                entry_out.predicted_taken <= `SD fetched_insts_in[0].preedicted_taken;
            end
            else if(write_en2) begin 
                entry_out.tag_1 <= `SD tag_1_in[1];
                entry_out.tag_2 <= `SD tag_2_in[1];
                entry_out.sq_dep <= `SD sq_deps_in[1];
                entry_out.dest_tag <= `SD dest_tag_in[1];
                entry_out.in_use <= `SD `TRUE;
                entry_out.decoded_inst <= `SD decoded_insts_in[1];
                entry_out.valid <= `SD `TRUE;
                entry_out.pc <= `SD fetched_insts_in[1].pc;
                entry_out.predicted_target <= `SD fetched_insts_in[1].predicted_target;
                entry_out.predicted_taken <= `SD fetched_insts_in[1].predicted_taken;
            end 
            else begin 
                entry_out.tag_1.ready <= `SD n_tag_1_ready;
                entry_out.tag_2.ready <= `SD n_tag_2_ready;
                entry_out.sq_dep.ready <= `SD n_sq_dep_ready;
                if(free_entry)
                    entry_out.in_use <= `SD `FALSE;
            end
        end
    end 

endmodule

module rs(
    input clock,
    input reset,
    input TAG_AND_READY [1:0] tag_1, //comes from internal signals of dispatch stage
    input TAG_AND_READY [1:0] tag_2,
    input TAG_AND_READY [1:0] sq_deps, //comes from internal signals of dispatch stage
    input IF_INST_OUT [1:0] fetched_insts, //from fetch stage
    input issue_to_alu, // input from alu FU in ex stage
    input issue_to_mult, //input from multiplier FU in ex stage
    input issue_to_load, 
    input issue_to_store,
    input PREG [1:0] dest_tag, //comes from free list pregs that are free to claim
    input DECODE_INST_OUT [1:0] decoded_insts, //comes from decoder
    input CDB_PACKET [1:0] cdb, //comes from cdb in complete stage
    input [1:0] num_to_dispatch, //comes from free list again 
    input PREG sq_ready_tag, //input to the dispatch stage

    output logic [1:0] num_rs_can_dispatch,
    output RS_ENTRY issued_entry_alu,
    output RS_ENTRY issued_entry_mult,
    output RS_ENTRY issued_entry_load,
    output RS_ENTRY issued_entry_store
    `ifdef DEBUG_RS
        ,output RS_ENTRY [15:0] test_entry 
    `endif

);

    parameter NUM_RS_ENTRIES = 16;
    logic [NUM_RS_ENTRIES-1:0] ready_outs_alu, ready_outs_mult, avail_outs, free_entrys_alu, free_entrys_mult, write_ens, write_ens2;
    logic [NUM_RS_ENTRIES-1:0] ready_outs_store, ready_outs_load, free_entrys_load, free_entrys_store;
    logic req_up, req_up2, req_up3, req_up4, req_up5, req_up6;
    RS_ENTRY [NUM_RS_ENTRIES-1:0] entry_outs;

    `ifdef DEBUG_RS
        assign test_entry = entry_outs;
    `endif

    always_comb begin 
        num_rs_can_dispatch = 2'h0;
        issued_entry_alu = 0;
        issued_entry_mult = 0;
        issued_entry_load = 0;
        issued_entry_store = 0;
        for (int i=0;i<NUM_RS_ENTRIES;i++) begin
            if(avail_outs[i] && (num_rs_can_dispatch < 2'h2)) begin 
                num_rs_can_dispatch = num_rs_can_dispatch + 1;
            end

            if(free_entrys_alu[i])
                issued_entry_alu = entry_outs[i];
            if(free_entrys_mult[i])
                issued_entry_mult = entry_outs[i];
            if(free_entrys_load[i])
                issued_entry_load = entry_outs[i];
            if(free_entrys_store[i])
                issued_entry_store = entry_outs[i];
        end
    end

    rs_entry entries [NUM_RS_ENTRIES-1:0] (
        .reset(reset),
        .clock(clock),
        .tag_1_in(tag1),
        .tag_2_in(tag2),
        .sq_deps_in(sq_deps),
        .fetched_insts_in(fetched_insts),
        .dest_tag_in(dest_tag),
        .decoded_insts_in(decoded_insts),
        .write_en(write_ens),
        .write_en2(write_ens2),
        .cdb_in(cdb),
        .sq_ready_tag_in(sq_ready_tag),
        .free_entry(free_entrys_alu | free_entrys_mult | free_entrys_load | free_entrys_store),
        .entry_out(entry_outs),
        .ready_out_alu(ready_outs_alu),
        .ready_out_mult(ready_outs_mult),
        .ready_out_load(ready_outs_load),
        .ready_out_store(reeady_outs_store),
        .avail_out(avail_outs)
    );

    //use priority selector to choose which RS entries are dispatched
    // takes in all avail outs as requests and chooses 1 entry to write to 
    //use 2 ps since we are 2 way superscalar
    ps #(.NUM_BITS(NUM_RS_ENTRIES)) ps1_dispatch(
        .req(avail_outs),
        .en(num_to_dispatch[1] | num_to_dispatch[0]),
        .gnt(write_ens),
        .req_up(req_up)
    );

    //second ps has req signal xor'd with the gnt from first ps
    // to avoid writing to same RS entry
    ps #(.NUM_BITS(NUM_RS_ENTRIES)) ps2_dispatch(
        .req(avail_outs ^ write_ens),
        .en(num_to_dispatch[1]),
        .gnt(write_ens2),
        .req_up(req_up2)
    );

    //ps that issues an instruction to the ALU functional unit
    ps #(.NUM_BITS(NUM_RS_ENTRIES)) ps1_issue_alu(
        .req(ready_outs_alu),
        .en(issue_to_alu),
        .gnt(free_entrys_alu),
        .req_up(req_up3)
    );

    //ps that issues an instruction to the multiplier functional unit
    ps #(.NUM_BITS(NUM_RS_ENTRIES)) ps1_issue_mult(
        .req(ready_outs_mult),
        .en(issue_to_mult),
        .gnt(free_entrys_mult),
        .req_up(req_up4)
    );

    //ps that issues an instruction to the load functional unit
    ps #(.NUM_BITS(NUM_RS_ENTRIES)) ps1_issue_load(
        .req(ready_outs_load),
        .en(issue_to_load),
        .gnt(free_entrys_load),
        .req_up(req_up5)
    );

    //ps that issues an instruction to the store functional unit
    ps #(.NUM_BITS(NUM_RS_ENTRIES)) ps1_issue_store(
        .req(ready_outs_store),
        .en(issue_to_store),
        .gnt(free_entrys_store),
        .req_up(req_up6)
    );

endmodule

module rs_entry (
    input clock, 
    input reset,
    input TAG_AND_READY [1:0] tag_1_in, 
    input TAG_AND_READY [1:0] tag_2_in,
    input TAG_AND_READY [1:0] sq_dep_in,
    input PREG [1:0] dest_tag_in,
    input PREG sq_tag_ready_in,
    input CDB_PACKET cdb_in,
    input IF_INST_OUT fetched_inst_in,
    input ID_INST_OUT [1:0] decoded_inst_in,
    input free_entry,
    input write_en,
    input write_en2,
    
    output logic avail_outs,
    output RS_ENTRY entry_out,
    output logic ready_out_alu,
    output logic ready_out_mult,
    output logic ready_out_load,
    output logic ready_out store;
);

    logic ready, n_tag_1_ready, n_tag_2_ready;

    assign avail_out = (entry_out.in_use == `FALSE);
    assign n_tag_1_ready = entry_out.tag_1.ready | (entry_out.tag_1.tag == cdb_in[0].tag) | (entry_out.tag_1.tag == cdb_in[1].tag);
    assign n_tag_2_ready = entry_out.tag_2.ready | (entry_out.tag_2.tag == cdb_in[0].tag) | (entry_out.tag_2.tag == cdb_in[1].tag);
    assign n_sq_tag_ready = entry_out.sq_dp.ready | (entry_out.sq_dep.tag == sq_dp_tag_ready_in);
    assign ready =  entry_out.in_use & n_tag_1_ready & n_tag_2_ready;
    assign ready_out_alu = ready & (decoded_inst_in.fu == ALU);
    assign ready_out_mult = ready & (decoded_inst_in.fu == MULT);
    assign ready_out_load = ready & (decoded_inst_in.fu == LOAD);
    assign ready_out_store = ready & (decoded_inst_in.fu == STORE);

    always_ff @(posedge clock) begin 
        if(reset | free_entry) begin 
            entry_out.tag_1 <= `SD '{6'b0,1'b0};
            entry_out.tag_2 <= `SD '{6'b0,1'b0};
            entry_out.sq_dep <= `SD '{`ZERO_PREG,`FALSE};
            entry_out.dest_tag <= `SD '{6'b0};
            entry_out.in_use <= `SD `FALSE;
            entry_out.pc <= `SD 32'd0;
            entry_out.valid <= `SD `FALSE;
            entry_out.predicted_target <= `SD 32'd0;
            entry_out.predicted_taken <= `SD `FALSE;
            entry_out.decoded_inst <= `SD '{`NOP,ALU_ADD,ALU,OPA_IS_RS1,OPB_IS_RS2,WORD,
                                            1'b0, //cond_branch
                                            1'b0, //uncond_branch
                                            1'b0, //rs1_used
                                            1'b0, //rs2_used
                                            1'b0, //has_dst
                                            1'b0, //rd_mem
                                            1'b0, //signed_rd,
                                            1'b0, //wr_mem,
                                            1'b0, //csr_op
                                            1'b0, //halt
                                            1'b0 //illegal
                                            };
        else if(write_en) begin 
            entry_out.tag_1 <= `SD tag_1_in[0];
            entry_out.tag_2 <= `SD tag_2_in[0];
            entry_out.sq_dep <= `SD sq_dep_in[0];
            entry_out.dest_tag <= `SD dest_tag_in[0];
            entry_out.decoded_inst <= `SD decoded_inst_in[0];
            entry_out.in_use <= `SD `TRUE;
            entry_out.pc <= `SD fetched_inst_in[0].pc;
            entry_out.predicted_target <= `SD fetched_inst_in[0].predicted_target;
            entry_out.predicted_taken <= `SD fetched_inst_in[0].predicted_taken;
            entry_out.valid <= `SD `TRUE;
        end else if(write_en2) begin
            entry_out.tag_1 <= `SD tag_1_in[1];
            entry_out.tag_2 <= `SD tag_2_in[1];
            entry_out.sq_dep <= `SD sq_dp_in[1];
            entry_out.dest_tag <= `SD dest_tag_in[1];
            entry_out.decoded_inst <= `SD decoded_inst_in[1];
            entry_out.in_use <= `SD `TRUE;
            entry_out.pc <= `SD fetched_inst_in[1].pc;
            entry_out.predicted_target <= `SD fetched_inst_in[1].predicted_target;
            entry_out.predicted_taken <= `SD fetched_inst_in[1].predicted_taken;
            entry_out.valid <= `SD `TRUE;
        end else begin 
            entry_out.tag_1.ready <= `SD n_tag_1_ready;
            entry_out.tag_2.ready <= `SD n_tag_2_ready;
            entry_out.sq_dp.ready <= `SD n_sq_dep_ready;
            if(free_entry)
                entry_out.in_use <= `SD `FALSE;
        end

endmodule 

module rs(
    input reset, 
    input clock, 
    input TAG_AND_READY [1:0] tag1,
    input TAG_AND_READY [1:0] tag2,
    input TAG_AND_READY sq_deps,
    input PREG [1:0] dest_tag,
    input issue_to_alu,
    input issue_to_mult,
    input issue_to_load,
    input issue_to_store,
    input IF_INST_OUT [1:0] fetched_insts,
    input ID_INST_OUT [1:0] decoded_insts,
    input CDB_PACKET cdb, 
    input PREG sq_ready_tag,
    input num_to_dispatch,

    output RS_ENTRY issued_to_alu,
    output RS_ENTRY issued_to_mult,
    output RS_ENTRY issued_to_store,
    output RS_ENTRY issued_to_load,

    output logic [1:0] num_rs_can_dispatch 

);



    parameter NUM_RS_ENTRIES = 16;
    logic [NUM_RS_ENTRIES-1:0] free_entrys_alu,ready_outs,alu, free_entrys_mult,ready_outs_mult,free_entrys_load,read_outs_load,free_entrys_store,read_outs_store,avail_outs,write_ens,write_ens2;

    always_comb begin 
        num_rs_can_dispatch = 0;
        issued_to_alu = 0; 
        issued_to_mult = 0; 
        issued_to_store = 0;
        issued_to_laod = 0;
        for(int i =0; i<NUM_RS_ENTRIES;i++) begin 
            if(avail_outs[i] && num_rs_can_dispatch < 2'h2) begin 
                num_rs_can_dispatch = num_rs_can_dispatch + 1;
            end

            if(free_entrys_alu[i])
                issued_to_alu = entry_outs[i];
            if(free_entrys_mult[i])
                issued_to_mult = entry_outs[i];
            if(free_entrys_store[i])
                issued_to_store = entry_outs[i];
            if(free_entrys_load[i])
                issued_to_load = entry_outs[i];
        end
    end

    rs_entry entries [NUM_RS_ENTRIES-1:0] (
        .reset(reset),
        .clock(clock),
        .tag_1(tag1),
        .tag_2(tag2),
        .dest_tag_in(dest_tag),
        .sq_deps_in(sq_dep),
        .fetched_inst_in(fetched_inst),
        .decoded_inst_in(decoded_inst),
        .cdb_in(cdb),
        .free_entry(free_entry_alu | free_entry_mult | free_entry_store | free_entry_load),
        .write_en(write_ens),
        .write_en2(write_ens2),
        .entry_out(entry_outs),
        .sq_tag_ready_in(sq_tag_ready),
        .ready_out_alu(ready_outs_alu),
        .ready_out_mult(ready_outs_mult),
        .ready_out_store(ready_outs_store),
        .ready_out_load(ready_outs_load),
        .avail_out(avail_outs)
    );

    ps #(.NUM_BITS(NUM_RS_ENTRIES)) (
        .req(avail_outs),
        .en(num_to_dispach[0] | num_to_dispatch[1]),
        .gnt(write_ens),
        .req_up(req_up)
    );

    ps #(.NUM_BITS(NUM_RS_ENTRIES)) (
        .req(write_ens ^ avail_outs),
        .en(num_to_dispatch[1]),
        .gnt(write_ens2),
        .req_up(req_up2)
    );

    ps #(.NUM_BITS(NUM_RS_ENTRIES)) (
        .req(ready_outs_alu),
        .en(issue_to_alu),
        .gnt(free_entrys_alu),
        .req_up(req_up3)
    );

    ps #(.NUM_BITS(NUM_RS_ENTRIES)) (
        .req(ready_outs_mult),
        .en(issue_to_mult),
        .gnt(free_entrys_mult),
        .req_up(req_up4)
    );

    ps #(.NUM_BITS(NUM_RS_ENTRY)) (
        .req(ready_outs_store),
        .en(issue_to_store),
        .gnt(free_entrys_store),
        .req_up(req_up5)
    );

    ps #(.NUM_BITS(NUM_RS_ENTRY)) (
        .req(ready_outs_load),
        .en(issue_to_load),
        .gnt(free_entrys_load),
        .req_up(req_up6)
    );
