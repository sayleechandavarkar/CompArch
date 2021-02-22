typedef struct packed{
    PREG tag;
    logic [3:0] byte_mask;
    logic [`XLEN-3:0] addr;
    logic [`XLEN-1:0] value;
    logic ready;
    logic waiting_load;
} SQ_ENTRY_CONTENTS;

const SQ_ENTRY_CONTENTS EMPTY_SQ_ENTRY = '{
    `ZERO_PREG,
    4'b0,
    30'b0,
    `FALSE,
    `FALSE
};

module sq_entry(
    input reset,
    input clock,
    input SQ_DISPATCH_PACKET_IN[1:0] instrs_to_dispatch,
    input [1:0] num_to_dispatch,
    input [1:0] dispatch_store_en,
    input dispatch_load_en,
    input tag_was_broadcast,
    input ST_EX_PACKET_OUT st_ex_out,
    input SQ_ENTRY_CONTENTS subsq_entry,
    input copy_subsq_en,

    output SQ_ENTRY_CONTENTS contents,
    output PREG tag,
    output logic ready, 
    output logic waiting_load
);

SQ_ENTRY_CONTENTS n_contents;

assign tag = n_contents.tag;
assign ready = n_contents.ready;

wire dispatch_ld0 = dispatch+load_en & (num_to_dispatch != 0) & instrs_to_dispatch[0].is_load;
wire dispach_ld1 = dispatch_load_en & (num_to_dispatch == 2) & instrs_to_dispatch[1].is_load;

always_comb begin 
    n_contents = contents;
    if(copy_subsq_en) begin 
        n_contents = subsq_entry;
    end 

    if(dispatch_store_en[0] | dispatch_store_en[1]) begin 
        n_contents.addr = 0;
        n_contents.value = 0; 
        n_contents.ready = 0;
        n_contents.waiting_load = 0;
    end
    if(dispatch_store_en[0]) begin  
        n_contents.tag = instrs_to_dispatch[0].tag;
    end else if(dispatch_sttore_en[1]) begin 
        n_contents.tag = instrs_to_dispatch[1].tag;
    end
    if(dispatch_ld0 | dispatch_ld1) begin 
        n_contents.waiting_load = `TRUE;
    end

    if(st_ex_out.tag != 0 & st_ex_out.tag == n_contents.tag) begin 
        n_contents.value = st_ex_out.value;
        n_contents.byte_mask = st_ex_out.byte_mask;
        n_contents.addr = st_ex_out.addr;
        n_contents.ready = `TRUE;
    end

    if(tag_was_broadcast) begin
        n_contents.waiting_load = `FALSE;
    end
end

always_ff @(posedge clock) begin
    if(reset) begin 
        contents.tag <= `SD `ZERO_PREG;
        contents.byte_mask <= `SD 4'b0;
        contents.addr <= `SD 0; 
        contents.value <= `SD 0;
        contents.ready <= `SD 0; 
        contents.waiting_load <= `SD 0; 
    end else begin 
        contents <= `SD n_contents;
    end
end

module store_queue #(
    SIZE =6)(
        input reset,
        input clock, 

        //dispatch inputs
        input SQ_DISPATCH_PACKET_IN [1:0] instrs_to_dispatch, 
        input [1:0] num_to_dispatch,

        //execute input  (stores)
        input ST_EX_PACKET_OUT st_ex_out,
        //execute input (loads)
        input LD_EX_PACKET_OUT ld_ex_out,

        //retire input 
        input ROB_PACKET_OUT [1:0] rob_retire_out,
        input [1:0] retire_en,

        //dispatch output
        output logic [1:0] num_sq_can_dispatch,
        output TAG_AND_READY tag_for_dispatching_load,

        //issue output 
        output PREG sq_ready_tag,

        //execute output 
        output SQ_FORWARDED_LOAD_OUT forwarded_ld_out,

        //dcache output 
        output PROC2DCACHE_REG proc2dcache_req_store
    );

        logic [$clog2(SIZE+1)-1:0] tail, n_tail, post_retire_tail;
        logic [$clog2(SIZE)-1:0] last_valid;

        SQ_ENTRY_CONTENTS [SIZE:0] entry_contents;
        assign entry_contents[SIZE] = EMPTY_SQ_ENTRY:

        PREG [SIZE-1:0] entry_tags;
        logic [SIZE-1:0] entry_readies;
        logic [SIZE-1:0] entry_waiting_loads;
        logic [SIZE-1:0] all_ready_so_far;

        always_comb begin 
            all_ready_so_far[0] = entry_readies[0];
            for(int i=1; i< SIZE; i++) begin 
                all_ready_so_far[i] = all_ready_so_far[i-1] & entry_readies[i];
            end
        end

        wire retire_st = (retire_en[0] & rob_retire_out[0].is_store | retire_en[1] & rob_retire_out[1].is_store);
        assign post_retire_tail = (retire_st & tail != 0)? tail -1 : tail;

        assign num_sq_can_dispatch = (post_retire_tail == SIZE) ? 2'h0:
                                    (post_retire_tail == SIZE -1) ? 2'h1: 2'h2;
                                
        wire dispatch_st0 = (num_to_dispatch != 0) & instrs_to_dispatch[0].is_store;
        wire dispatch_st1 = (num_to_dispatch == 0) & instrs_to_dispatch[1].is_store;

        assign last_valid = dispatch_st0? post_retire_tail : post_retire_tail-1;
        wire will_be_empty = ~dispatch_st0 & (post_retire_tail ==0);

        assign tag_for_dispatching_load.tag = will_be_empty? `ZERO_PREG: entry_tags[last_valid];
        assign tag_for_dispatching_load.ready = will_be_empty | all_ready_so_far[last_valid];

        assign proc2dcache_req_store.action = retire_st?REQ_STORE:REQ_NONE;

        logic [1:0] byte_offset;

        assign proc2dcache_req_store.data = entry_contents[0].value >> 8*byte_offset;
        assign proc2dcache_req_store.addr = {entry_contents[0].addr, byte_offset};

        always_comb begin
            proc2dcache_req_store.size = WORD;
            byte_offset = 0; 

            case(entry_contents[0].byte_mask)
                4'b0001: begin 
                    proc2dcache_req_store.size = BYTE;
                    byte_offset = 0; 
                end
                4'b0010: begin 
                    proc2dcache_req_store.size = BYTE;
                    byte_offset = 1;
                end
                4'b0100: begin 
                    proc2dcache_req_store.size = BYTE; 
                    byte_offset = 2; 
                end
                4'b1000: begin 
                    proc2dcache_req_store.size = BYTE; 
                    byte_offset = 3;
                end
                4'b0011: begin 
                    proc2dcache_req_store.size = HALF;
                    byte_offset = 0;
                end 
                4'b0110: begin 
                    proc2dcache_req_store.size = HALF; 
                    byte_offset = 1; 
                end 
                4'b1100: begin 
                    proc2dcache_req_store.size = HALF;
                    byte_offset = 2; 
                end
            endcase
        end 

        wor [SIZE-1:0] entry_tag_was_broadcast;

        generate 
            genvar i; 

            for( i = 0; i < SIZE; i++) begin 
                wire dispatch_st_en0 = dispatch_st0 & (i == post_retire_tail);
                wire dispatch_st_en1 = dispatch_st1 & (((i == post_retire_tail) & ~dispatch_st0) | ((i == post_retire_tail+1) & dispatch_st0));
                wire dispatch_load_en = (i == last_valid); 

                sq_entry_sqe(
                    .reset(reset),
                    .clock(clock),
                    .num_to_dispatch(num_to_dispatch),
                    .instrs_to_dispatch(instrs_to_dispatch),
                    .dispatch_sttore_en(dispatch_load_en),
                    .tag_was_broadcast(entry_tag_was_broadcast[i]),
                    .st_ex_out(st_ex_out),
                    .subsq_entry(entry_contents[i+1]),
                    .copy_subsq_en(retire_st),

                    .contents(entry_contents[i]),
                    .tag(entry_tags[i]),
                    .ready(entry_readies[i]),
                    .waiting_load(entry_waiting_loads[i]),
                );

        endgenerate

        logic req_up;
        PREG ready_tag;

        assign sq_ready_tag = req_up? ready_tag: `ZERO_PREG;

        reverse_priority_mux #($bits(PREG), SIZE) tag_broadcast(
            .en(1'b1),
            .reqs(all_ready_so_far & entry_waiting_loads),
            .data_in(entry_tags),

            .enables(entry_tag_was_broadcast),
            .data_out(ready_tag),
            .req_up(req_up)
        ); 

        logic [SIZE-1:0] [7:0] entry_values_by_byte [3:0];
        logic [SIZE-1:0] earlier_than_load; 
        logic [SIZE-1:0] availbale_for_forwarding [3:0];

        always_comb begin
            earlier_than_load = 0; 
            if(ld_ex_out.last_older_store_tag != `ZERO_PREG) begin 
                earlier_than_load[SIZE-1] = (entry_contents[SIZE-1].tag == ld_ex_out.last_older_store_tag);
                for(int i = SIZE-2; i>= 0; i--) begin 
                    earlier_than_load[i] = earlier_than_load[i+1] | entry_contents[i].tag == ld_ex_out.lat_older_store_tag;
                end 
            end 
            for(int i = 0; i < SIZE; i++) begin 
                for(int j = 0; j < 4; j++) begin 
                    available_for_forwarding[j][i] = earlier_than_load[i]
                                                    & entry_contents[i].addr == ld_eex_out.addr
                                                    & entry_contents[i].byte_mask[j];
                end
            end

            for(int i=0;i <SIZE; i++) begin 
                for(int j=0;j<4;j++) begin 
                    entry_values_by_byte[j][i] = entry_contents[i].value[(j*8)+7 -: 8];
                end 
            end


            //forwarding logic
            generate 
                genvar j;

                for(j=0;j < (`XLEN/8); j++) begin 
                    priority_mux #(8,SIZE) pm(
                        .en(1'b1),
                        .reqs(available_for_forwarding[j]),
                        .data_in(entry_values_by_byte[j]),
                        .enables(),
                        .data_out(forwarded_ld_out.value[(j*8)+7:(j*8)]),
                        .req_up(forwarded_ld_out.byte_mask[j])
                    );
                end 
            endgenerate

            //logic for updating tail 

            always_comb begin 
                n_tail = post_retire_tail; 
                if(dispatch_st0)
                    n_tail = n_tail+1; 
                if(dispach_st1)
                    n_tail = n_tail+1;
            end

            //synopsys sync_reset 
            always_ff @(posedge clock) begin 
                if(reset) begin 
                    tail <= `SD 0; 
                end else begin 
                    tail <= `SD n_tail; 
                end
            end 

endmodule 

module priority_mux #(
    DATA_WIDTH=1, HEIGHT=8)(
    input en, 
    input [HEIGHT-1:0] reqs, 
    input [HEIGHT-1:0] [DATA_WIDTH-1:0] data_in, 

    output logic [HEIGHT-1:0] enables, 
    output logic [DATA_WIDTH-1:0] data_out, 
    output logic req_up
    );

    always_comb begin 
        enables = 0; 
        data_out = 0; 
        req_up = 0; 
        if(en) begin 
            for(int i=0;i<HEIGHT;i++) begin 
                if(reqs[i]) begin 
                    req_up = 1'b1;
                    enables = 1'b1 << i; 
                    data_out = data_in[i];
                end
            end
        end 
    end 
endmodule 

module reverse_priority_mux #(
    DATA_WIDTH=1,HEIGHT=8)(
    input en,
    input [HEIGHT-1:0] reqs,
    input [HEIGHT-1:0] [DATA_WIDTH-1:0] data_in,

    output logic [HEIGHT-1:0] enables,
    output logic [DATA_WIDTH-1:0] data_out,
    output logic req_up
    );

    always_comb begin 
        enables = 0;
        data_out = 0; 
        req_up = 0; 
        if(en) begin 
            for(int i = HEIGHTT-1; i>= 0; i--) begin 
                if(reqs[i]) begin 
                    req_up = 1'b1; 
                    enables = 1'b1 << 1; 
                    data_out = data_in[i];
                end
            end
        end
endmodule 

