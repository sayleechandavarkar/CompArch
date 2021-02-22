module dispatch(
    input clock,
    input reset,
    IF_INST_OUT [1:0] fetched_insts,
    input [1:0] num_valid_insts,
    input issue_to_alu,
    input issue_to_mult,
    input issue_to_load,
    input issue_to_store,
    input can_retire_store,
    input CDB_PACKET [1:0] cdb_in.
    input [1:0] num_sq_can_dispatch,
    input TAG_AND_READY tag_for_dispatching_load,
    input PREG sq_ready_tag,
    input program_finished,

    output logic [1:0] num_to_dispatch, 
    output RS_ENTRY issued_entry_alu,
    output RS_ENTRY issued_entry_mult,
    output RS_ENTRY issued_entry_load,
    output RS_ENTRY issued_entry_store,
    output ROB_PACKET_OUT [1:0] rob_retire_out,
    output logic [1:0] retire_en,

    output logic retiring_misprediction,
    output logic [`XLEN-1:0] misprediction_target_pc,
    output SQ_DISPATCH_PACKET_IN [1:0] instrs_to_dispatch

);

    logic done_rewinding,
    AREG [5:0] arch_reg;
    PREG [1:0] preg_to_claim;
    PREG [1:0] preg_to_claim;
    logic [1:0] num_rs_dispatch, num_rob_can_dispatch, true_num_sq_can_dispatch;
    logic [2:0] rewind_en;
    TAG_AND_READY [1:0] mt_write_data;
    logic [1:0] mt_write_en;
    TAG_AND_READY [1:0] amt_write_data;
    TAG_AND_READY [5:0] tags_from_mt;
    PREG [1:0] t_old;
    TAG_AND_READY [1:0] p_rs1;
    TAG_AND_READY [1:0] ps_rs2;
    TAG_AND_READY [1:0] sq_deps;
    ROB_PACKET_IN [1:0] rob_dispatch_in;
    ROB_PACKET_OUT [2:0] rob_rewind_out;
    PREG [4:0] preg_to_free;
    logic [4:0] free_en;
    DECODE_INST_OUT [1:0] decoded_inst;
    TAG_AND_READY [`NUM_AREGS-1:0] amt_copy_data;

    EXECUTION_STATE state, n_state;

    //inputs to map table 
    assign arch_reg = {
        fetched_insts[1].inst.r.rs2,
        fetched_insts[1].inst.r.rs1,
        fetched_insts[1].inst.r.rd,
        fetched_insts[0].inst.r.rs2,
        fetched_insts[0].inst.r.rs1.
        fetched_insts[0].inst.r.rd
    };

    //depending on if dispatching insts are stores, the num_sq_can_dispatch can change
    //instrs to dispatch[0] is instruction at pc and [1] is instruction at pc+4
    assign true_num_sq_can_dispatch = (~instrs_to_dispatch[1].is_store & ~instrs_to_dispatch[0].is_store)? 2'h2:
                                    (~instrs_to_dispatch[1].is_store & instrs_to_dispatch[0].is_store)? ((num_sq_can_dispatch == 0)?2'h0:2'h2):
                                    (instrs_to_dispatch[1].is_store & ~instrs_to_dispatch[0].is_store)? ((num_sq_can_dispatch == 0)?2'h1:2'h2):num_sq_can_dispatch;

    //find the min between num_rs_can_dispatch num_rob_can_dispatch num_valid_insts and true_num_sq_can_dispatch
    assign num_to_dispatch = program_finished? 2'h0:
                            (state != NORMAL_EXECUTION) ? 2'h0:
                            (num_rs_can_dispatch <= num_rob_can_dispatch) & (num_rs_can_dispatch <= num_valid_insts) &(num_rs_can_dispatch <= true_num_sq_can_dispatch) ? num_rs_can_dispatch:
                            (num_rob_can_dispatch <= num_rs_can_dispatch) & (num_rob_can_dispatch <= num_valid_insts) &(num_rob_can_dispatch <= true_num_sq_can_dispatch) ? num_rob_can_dispatch:
                            (num_valid_insts <= num_rs_can_dispatch) & (num_valid_insts <= num_rob_can_dispatch) & (num_valid_insts <= true_num_sq_can_dispatch)? num_valid_insts : true_num_sq_can_dispatch;

    assign retiring_misprediction = (retire_en[1] & rob_retire_out[1].misprediction) | (retire_en[0] & rob_retire_out.misprediction[0].misprediction);


    //garbage if retiring misprediction 
    //if branch is taken the target pc is branch target of the retiring instruction 
    //if branch is not taken then target pc will be pc+4 of the retiring instruction 
    assign misprediction_target_pc = retire_en[1]? 
                                    (rob_retire_out[1].taken_branch? rob_retire_out[1].branch_target: rob_retire_out[1].pc + 4):
                                    (rob_retire_out[0].taken_branc? rob_retire_out[0].branch_target: rob_retire_out[0].pc + 4);

    //assign output to store queue
    assign instrs_to_dispatch[1] = '{preg_to_claim[1], p_rs1[1], decoded_inst[1].rd_mem, decoded_inst[1].wr_mem};
    assign instrs_to_dispatch[0] = '{preg_to_claim[0], p_rs1[0], decoded_inst[0].rd_mem, decoded_inst[0].wr_mem};

    //assign store queue dependencies for rs
    always_comb begin 
        sq_deps[1] = '{`ZERO_PREG, `TRUE};
        sq_deps[0] = '{`ZERO_PREG, `TRUE};
        if(decoded_inst[1].rd_mem) //if load
            sq_deps[1] = tag_for_dispatching_for_load;

        if(decoded_inst[0].rd_mem) //if load
            sq_deps[0] = tag_for_dispatching_for_load;

    end

    always_comb begin 
        case(state)
            NORMAL_EXECUTION: n_state = (cdb_in[1].misprediction | cdb_in[0].misprediction)? BR_REWIND_AND_RETIRE: NORMAL_EXECUTION;
            BR_REWIND_ONLY: n_state = done_rewinding? NORMAL_EXECUTION: BR_REWIND_ONLY;
            BR_REWIND_AND_RETIRE: n_state = done_rewinding? NORMAL_EXECUTION:
                                            retiring_misprediction? BR_REWIND_ONLY: BR_REWIND_AND_RETIRE;
    end

    always_comb begin 
        for(int i=0;i<2;i++) begin 
            rob_dispatch_in[i].inst = fetched_insts[i].inst;
            rob_dispatch_in[i].pc = fetched_insts[i].pc;
            rob_dispatch_in[i].arch_dst = decoded_inst[i].has_dst? fetched_insts[i].inst.r.rd: `ZERO_PREG;
            rob_dispatch_in[i].tag = preg_to_claim[i];
            rob_dispatch_in[i].t_old = t_old[i];
            rob_dispatch_in[i].is_store = decoded_inst.wr_mem;
        end 
    end

    always_comb begin 
        //instructions with no dst free their tag when they retire
        t_old[0] = decoded_inst[0].has_dst? tags_from_mt[0].tag: preg_to_claim[0];
        p_rs1[0] = decoded_inst[0].rs1_used? tags_from_mt[1]: '{ZERO_PREG, `TRUE};
        ps_rs2[0] = decoded_inst[1].rs2_used? tags_from_mt[2]: '{ZERO_PREG, `TRUE};
        
        //just default values before it is checked if they have dst or not
        t_old[1] = tags_from_mt[3].tag;
        p_rs1[1] = tags_from_mt[4];
        p_rs2[1] = tags_from_mt[5];

        if(decoded_isnt[0].has_dst & fetched_insts[0].inst.r.rd != `ZERO_REG) begin 
            if(fetched_insts[1].inst.r.rd == fetched_insts[0].inst.r.rd)
                t_old[1] = preg_to_claim[0];
            if(fetched_insts[1].inst.r.rs1 == fetched_insts[0].inst.r.rd)
                p_rs1[1] = '{preg_to_claim[0], `FALSE};
            if(decoded_insts[1].inst.r.rs2 == fetched_insts[0].inst.r.rd)
                p_rs2[1] = '{preg_to_claim[0], `FALSE}; 
        end

        if(~decoded_inst[1].has_dst)
            t_old[1] = preg_to_claim[1];
        if(~decoded_inst[1]).rs1_used)
            p_rs1[1] = '{`ZERO_PREG, `TRUE};
        if(~decoded_inst[1].rs2_used)
            p_rs2[1] = '{`ZERO_PREG, `TRUE};
    end

    //for map table
    assign mt_write_en[0] = (num_to_dispatch != 0) & decoded_inst[0].has_dst;
    assign mt_write_en[1] = (num_to_dispatch == 2) & decoded_inst[1].has_dst;

    assign mt_write_data[0] = '{preg_to_claim[0], `FALSE};
    assign mt_write_data[1] = '{preg_to_claim[1], `FALSE};

    assign amt_write_data[0] = '{rob_retire_out[0].tag, `TRUE};
    assign amt_write_data[1] = '{rob_retire_out[1].tag, `TRUE};

    //assign for free list
    assign preg_to_free = {rob_rewind_out[2].tag, rov_rewind_out[1].tag, rob_rewind_out[0].tag, rob_retire_out[1].t_old, rob_retire_out[0].t_old};
    assign free_en = {rewind_en, retire_en};

    always_ff @(posedge clock) begin 
        if(reset) begin 
            state <= `SD NORMAL_EXECUTION;
        end else begin 
            state <= `SD n_state;
    end
 
    map_table mt(
        .reset(reset),
        .clock(clock),
        .cdb(cdb_in),
        .read(arch_reg),
        .write(arch_reg[3], arch_reg[0]),
        .write_data(mt_write_data),
        .write_en(mt_write_en),
        .copy_data_in(amt_copy_data),
        .copy_en(retiring_misprediction),
        .read_data(tags_from_mt),
        .copy_data_out()
    );

    //architectural map table
    map_table #(0,2)(
        .reset(reset),
        .clock(clock),
        .cdb(cdb_in),
        .read(),
        .write(rob_retire_out[1].arch_dst, rob_retire_out[0].arch_dst),
        .write_data(amt_write_data),
        .write_en(retire_en),
        .copy_data(),
        .copy_en[1],
        .read_data(),
        .copy_data_out(amt_copy_data)
    );

    //instantiate the reservation station
    rs #(.NUM_RS_ENTRIES(16)) rs0(
        .clock(clock),
        .reset(reset | retiring_misprediction),
        .tag_1(p_rs1),
        .tag_2(p_rs2),
        .sq_deps(sq_deps),
        .fetched_insts(fetched_insts),
        .issue_to_alu(issue_to_alu),
        .issue_to_mult(issue_to_mult),
        .issue_to_load(issue_to_load),
        .issue_to_store(issue_to_store),
        .dest_tag(preg_to_claim),
        .decoded_insts(decoded_inst),
        .cdb(cdb_in),
        .num_to_dispatch(num_to_dispatch),
        .sq_ready_tag(sq_ready_tag),
        .num_rs_can_dispatch(num_rs_can_dispatch),
        .issued_entry_alu(issued_entry_alu),
        .issued_entry_mult(issued_entry_mult),
        .issued_entryy_load(issued_entry_load),
        .issued_entry_store(issued_entry_store),
    );

    //instantiate re order buffer
    rob rob0(
        .reset(reset),
        .clock(clock),
        .rob_dispatch_in(rob_dispatch_in),
        .num_to_dispatch(num_to_dispatch),
        .state(state),
        .cdb(cdb_in),
        .can_retire_store(can_retire_store),
        .num_rob_can_dispatch(num_rob_can_dispatch),
        .rob_retire_out(rob_reire_out),
        .retire_en(retire_en),
        .rob_rewind_out(rob_rewind_out),
        .rewind_en(rewind_en),
        .done_rewinding(done_rewinding)
    );

    free_list list #(5)(
        .reset(reset),
        .clock(clock),
        .preg_to_free(preg_to_free),
        .free_en(free_en),
        .num_to_claim(num_to_dispatch),
        .preg_to_claim(preg_to_claim)
    );

    decoder dec [1:0](
        .inst_in(fetched_insts[1].inst,fetched_insts[0].inst),
        .decoded_inst(decoded_inst)
    );


module dispatch_stage(
    input clock,
    input reset,
    input IF_INST_OUT [1:0] fetched_insts,
    input [1:0] num_valid_insts,
    input issue_to_alu,
    input issue_to_mult,
    input issue_to_store,
    input issue_to_load,
    input can_retire_store,
    input CDB_PACKET [1:0] cdb_in,
    input [1:0] num_sq_can_dispatch, //num the store queue can take in 
    input TAG_AND_READY tag_for_dispatching_load,
    input PREG sq_ready_tag,
    input program_finished,


    output logic [1:0] num_to_dispatch,
    output RS_ENTRY issued_entry_alu,
    output RS_ENTRY issued_entry_mult,
    output RS_ENTRY issued_entry_store,
    output RS_ENTRY issued_entry_load,
    output ROB_PACKET_OUT [1:0] rob_retire_out,
    output logic [1:0] retire_en,
    output logic retiring_misprediction,
    output logic [`XLEN-1:0] misprediction_target_pc,
    output SQ_DISPATCH_PACKET_IN [1:0] instrs_to_dispatch
    
    );

    logic done_rewinding;
    AREG [5:0] arch_reg; //arch reg input to the map table
    PREG [1:0] pre_to_claim;
    logic [1:0] num_rs_can_dispatch, num_rob_can_dispatch, true_num_sq_can_dispatch;
    logic [2:0] rewind_en;
    TAG_AND_READY [1:0] mt_write_data;
    logic [1:0] mt_write_en;
    TAG_AND_READY [1:0] amt_write_data;
    TAG_AND_READY [5:0] tags_from_mt;
    PREG [1:0] t_old;
    TAG_AND_READY [1:0] p_rs1;
    TAG_AND_READY [1:0] p_rs2;
    TAG_AND_READY [1:0] sq_deps;
    ROB_PACKET_IN [1:0] rob_dispatch_in;
    ROB_PACKET_OUT [1:0] rob_rewind_out;
    PREG [4:0] preg_to_free;
    logic [4:0] free_en;
    DECODE_INST_OUT [1:0] decoded_inst;
    TAG_AND_READY [`NUM_AREGS-1:0] amt_copy_data;

    EXECUTION_STATE n_state, state;

    assign arch_reg = {
        fetched_insts[1].inst.r.rs2,
        fetched_insts[1].inst.r.rs1,
        fetched_insts[1].inst.r.rd,
        fetched_insts[0].inst.r.rs2,
        fetched_insts[0].inst.r.rs1,
        fetched_insts[0].inst.r.rd
    };

    //assign instructions to store queue
    assign instrs_to_dispatch[0] = '{preg_to_claim[0], p_rs1[0], decoded_inst[0].rd_mem, decoded_inst[0].wr_mem};
    assign instrs_to_dispatch[1] = '{preg_to_claim[1], p_rs1[1], decoded_inst[1].rd_mem, decoded_inst[1].wr_mem};

    //depending on 
    assign true_num_sq_can_dispatch = (~instrs_to_dispatch[1].is_store & ~instrs_to_dispatch[0].is_store)? 2'h2:
                                    (~instrs_to_dispatch[1].is_store & instrs_to_dispatch[0].is_store)? ((num_sq_can_dispatch == 0)? 2'h0: 2'h2):
                                    (instrs_to_dispatch[1].is_store & ~instrs_to_dispatch[0].is_store)? ((num_sq_can_dispatch == 0)? 2'h1: 2'h2): num_sq_can_dispatch;

    assign retiring_misprediction = (retire_en[1] & rob_retire_out[1].misprediction) | (retire_en[0] & rob_retire_out[0].misprediction);

    assign misprediction_target_pc = retire_en[1]?
                                    (rob_retire_out[1].taken_branch? rob_retire_out[1].branch_target : rob_retire_out[1].pc +4):
                                    (rob_retire_out[0].taken_branch? rob_retire_out[0].branch_target : rob_retire_out[0].pc +4);

    //assign store dependencies for rs
    always_comb begin
        sq_deps[1] = '{`ZERO_PREG, `TRUE};
        sq_deps[0] = '{`ZERO_PREG, `TRUE};
        if(decoded_inst[1].rd_mem)
            sq_deps[1] = tag_for_dispatching_for_load;
        if(decoded_inst[0].rd_mem)
            sq_deps[0] = tag_for_dispatching_for_load;
    end

    always_comb begin 
        for(int i=0;i<2;i++) begin 
            rob_dispatch_in[i].inst = fetched_insts[i].inst;
            rob_dispatch_in[i].pc = fetched_insts[i].pc;
            rob_dispatch_in[i].arch_dst = decoded_inst[i].has_dst? fetched_insts[i].r.rd: `ZERO_REG;
            rob_dispatch_in[i].tag = preg_to_claim[i];
            rob_dispatch_in[i].t_old = t_old[i];
            rob_dispatch_in[i].is_store = decoded_inst.wr_mem;
        end
    end

    always_comb begin 
            //instructions with no dst free their tag when they retire
            t_old[0] = decoded_inst[0].has_dst? tags_from_mt[0].tag : preg_to_claim[0];
            p_rs1[0] = decoded_insts[0].has_rs1? tags_from_mt[1].tag : '{`ZERO_PREG, `TRUE};
            p_rs2[0] = decoded_insts[0].has_rs2? tags_from_mt[2].tag : '{`ZERO_PREG, `TRUE};

            t_old[1] = tags_from_mt[3].tag;
            p_rs1[1] = tags_from_mt[4];
            p_rs2[1] = tags_from_mt[5];

            if(decoded_inst[0].has_dst & fetched_insts.inst.r.rd != `ZERO_PREG) begin 
                if(fetched_insts[1].inst.r.rd == fetched_insts[0].inst.r.rd)
                    t_old[1] = preg_to_claim[0];
                if(fetched_insts[1].inst.r.rs1 == fetched_insts[0].inst.r.rd)
                    p_rs1[1] = '{preg_to_claim[0], `FALSE};
                if(fetched_insts[1].inst.r.rs2 == fetched_insts[0].inst.r.rd)
                    p_rs2[1] = '{preg_to_claim[0], `FALSE};
            end

            if(~decoded_inst[1].has_dst)
                t_old[1] = preg_to_claim[1];
            if(~decoded_inst[1].has_rs1)
                p_rs1[1] = '{`ZERO_PREG, `FALSE};
            if(~decoded_inst[1].has_rs2)
                p_rs2[1] = '{`ZERO_PREG, `FALSE};

    end

assign mt_write_en[0] = (num_to_dispatch != 0) & decoded_inst[0].has_dst;
assign mt_write_en[1] = (num_to_dispatch == 2) & decoded_inst[1].has_dst;

assign mt_write_data[0] = '{preg_to_claim[0], `FALSE};
assign mt_write_data[1] = '{preg_to_claim[1], `FALSE};

assign amt_write_data[0] = '{rob_retire_out[0].tag, `TRUE};
assign amt_write_data[1] = '{rob_retire_out[1].tag, `TRUE};

assign preg_to_free = '{rob_rewind_out[2].tag, rob_rewind_out[1].tag, rob_rewind_out[0].tag, rob_retire_out[1].tag, rob_retire_out[0].tag};
assign free_en = {rewind_en, retire_en};

always_ff @(posedge clock) begin 
    if(reset)
        state <= `SD NOMRAL_EXECUTION;
    else 
        state <= `SD n_state;
end

