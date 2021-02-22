module rob_entry(
    input reset, 
    input clock, 
    input ROB_PACKET_IN dispatch_in,
    input [1:0] write_en,
    input CDB_PACKET cdb,
    output ROB_PACKET_OUT entry_inst,
    output logic entry_complete
);

    always_ff @(posedge clock) begin 
        if(reset) begin 
            entry_inst.inst <= `SD `NOP;
            entry_insty.pc <= `SD 32'h0;
            entry_inst.tag <= `SD `ZERO_PREG;
            entry_inst.t_old <= `SD `ZERO_PREG;
            entry_inst.arch_dst <= `SD `ZERO_PREG;
            entry_inst.is_store <= `SD `FALSE;
            entry_inst.misprediction <= `SD `FALSE;
            entry_inst.taken_branch <= `SD `FALSE;
            entry_inst.branch_target <= `SD `FALSE;
            entry_complete <= `SD `FALSE;
        end else if(write_en[0]) begin 
            entry_inst.inst <= `SD dispatch_in[0].inst;
            entry_inst.pc <= `SD dispatch_in[0].pc;
            entry_inst.tag <= `SD dispatch_in[0].tag;
            entry_inst.t_old <= `SD dispatch_in[0].t_old;
            entry_inst.arch_dst <= `SD dispatch_in[0].arch_dst;
            entry_inst.is_store <= `SD dispatch_in[0].is_store;
            entry_inst.misprediction <= `SD dispatch_in[0].misprediction;
            entry_inst.branch_target <= `SD dispatch_in[0].branch_target;
            entry_inst.taken_branch <= `SD dispatch_in[0].taken_branch;
            entry_complete <= `SD `FALSE;
        end else if(write_en[1]) begin 
            entry_inst.inst <= `SD dispatch_in[1].inst;
            entry_inst.pc <= `SD dispatch_in[1].pc;
            entry_inst.tag <= `SD dispatch_in[1].tag;
            entry_inst.t_old <= `SD dispatch_in[1].t_old;
            entry_inst.arch_dst <= `SD dispatch_in[1].arch_dst;
            entry_inst.is_store <= `SD dispatch_in[1].is_store;
            entry_inst.misprediction <= `SD dispatch_in[1].misprediction;
            entry_inst.branch_target <= `SD dispatch_in[1].branch_target;
            entry_inst.ttaken_branch <= `SD dispatch_in[1].taken_branch;
            entry_complete <= `SD `FALSE;
        end else if(entry_inst.tag == cdb[0].tag) begin 
            entry_inst.misprediction <= `SD cdb[0].misprediction;
            entry_inst.taken_branch <= `SD cdb[0].taken_branch;
            entry_inst.branch_target <= `SD cdb[0].branch_target;
            entry_complete <= `SD `TRUE;
        end else if(entry_inst.tag == cdb[1].tag) begin 
            entry_inst.misprediction <= `SD cdb[1].misprediction;
            entry_inst.taken_branch <= `SD cdb[1].taken_branch;
            entry_inst.branch_target <= `SD cdb[1].branch_target;
            entry_complete <= `SD `TRUE;
        end
    end

endmodule

module rob(
    input reset,
    input clock,
    input [1:0] num_to_dispatch,
    input EXECUTION_STATE state,
    input ROB_PACKET_IN rob_dispatch_in,
    input CDB_PACKET [1:0] cdb,
    input can_retire_store,
    output logic [1:0] num_rob_can_dispatch,
    output ROB_PACKET_OUT [1:0] rob_retire_out,
    output logic [1:0] retire_en,
    output ROB_PACKET_OUT [2:0] rob_rewind_out,
    output logic [2:0] rewind_en,
    output logic done_rewinding
);

    logic is_full,n_full;
    logic [1:0] entry_complete,num_retired;
    logic [$clog2(`ROB_SIZE)-1:0] head,tail,n_head,n_tail,head_plus_one,head_minus_one,tail_plus_one,tail_minus_one,tail_minus_two,tail_minus_three;
    logic [`ROB_SIZE-1:0] entry_completes;
    logic [`ROB_SIZE-1:0] [1:0] entry_write_ens;
    ROB_PACKET_OUT [`ROB_SIZE-1:0] entry_insts;

    rob_entry entries [`ROB_SIZE-1:0] (
        .reset(reset),
        .clock(clock),
        .dispatch_in(rob_dispatch_in),
        .write_en(entry_write_ens,
        .cdb(cdb),
        .entry_inst(entry_insts),
        .entry_complete(entry_completes)
    );

    assign head_plus_one = (head + 1) < `ROB_SIZE ? head+1:0;
    assign head_minus_one = head>0?head-1:`ROB_SIZE-1;
    assign tail_plus_one = tail+1 < `ROB_SIZE?tail+1:0;
    assign tail_minus_one = tail>0?tail-1:`ROB_SIZE-1;
    assign tail_minus_two = tail_minus_two >0:tail_minus_one-1:`ROB_SIZE-1;
    assign tail_minus_three = tail_minus_tthree>0:tail_minus_two:`ROB_SIZE-1;

    assign entry_complete[0] = entry_completes[head];
    assign entry_complete[1] = entry_completes[head_plus_one];
    assign rob_retire_out[0] = entry_insts[head];
    assign rob_retire_out[1] = entry_insts[head_plus_one];

    assign num_retired = retire_en[1]?2:retired_en[0]?1:0;
    assign rob_rewind_out[0] = entry_insts[tail_minus_one];
    assign rob_rewind_out[1] = entry_insts[tail_minus_two];
    assign rob_rewind_out[2] = entry_insts[tail_minus_three];
    assign rewind = (state == BR_REWIND_ONLY) | (state == BR_REWIND_AND_RETIRE);
    assign rewind_en[0] = rewind & ((tail != head) | ~is_full) & ((state == BR_REWIND_ONLY) | ~rob_rewind_out[0].misprediction);
    assign rewind_en[1] = rewind_en[0] & (tail_minus != head) & ((state == BR_REWIND_ONLY) | ~rob_rewind_out[1].misprediction);
    assign rewind_en[2] = rewind_en[1] & (tail_minus_two != head) & ((state == BR_REWIND_ONLY) | ~rob_rewind_out[2].misprediction);
    assign done_rewinding = head == tail & ~is_full;

    always_comb begin 
        //default case if instruction is completee then retire
        retire_en[0] = entry_complete[0] & (state != BR_REWIND_ONLY)
                        &(can_retire_store | ~rob_retire_out.is_store);
                
        retire_en[1] = retire_en[0] & entry_complete[1] & ~rob_retire_out[0].mispredict & ~rob_retire_out[0].is_store;
                        &(can_store_retire | ~rob_retire_out[1].is_store);
        num_rob_can_dispatch = 2'h2;
        if(head_plus_one == tail)
            retire_en[1] =0;
        else if((head == tail) & ~is_full)
            retire_en = 2'b0;
        else if(head == tail_plus_one)
            num_rob_can_dispatch = retire_en[0]?2'h2:2'h1;
        else if(is_full)
            num_rob_can_dispatch = retire_en[1]? 2'h2:retire_en[0]?2'h1:2'h0;
    end

    //decoder to decide which instruction to dispatch into ROB
    always_comb begin 
        entry_writte_ens = 0; 
        entry_write_ens[tail][0] = num_to_dispatch != 0;
        entry_write_ens[tail_plus_one] = num_to_dispatch == 2;
    end

    //next state logic for head, tail, is_full 
    always_comb begin 
        n_head = head + num_retired;
        if(n_head >= `ROB_SIZE)
            n_head = n_head - `ROB_SIZE;

        if(rewind) 
            n_tail = rewind_en[2]?tail_minus_three:rewind_en[1]?tail_minus_two:rewind_en[0]?tail_minus_one:tail;
        else 
            n_tail = n_tail + num_to_dispatch;

        if(is_full)
            n_full = (n_tail == n_head);
        else 
            n_full = (n_tail == n_head) & (num_to_dispatch > num_retired)
    end

    always_ff @(posedge clock) begin
        if(reset) begin
            head <= `SD 0;
            tail <= `SD 0;
            is_full <= `SD 0;
        end else begin
            head <= `SD n_head;
            tail <= `SD n_tail;
            is_full <= `SD n_full;
        end
    end

endmodule 
