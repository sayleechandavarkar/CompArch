module icache_controller(
    input clock, 
    input reset, 
    input [3:0] Imem2proc_rsponse, //0 -15 0 is rejected request
    input [63:0] Imem2proc_data, //single block of instr, back from mem
    input [3:0] Imem2proc_tag, //request number for return data, 0 is nothing

    input [31:0] pc, // rquested pc from processor to be fetched
    input [31:0] prefetch_pc, //prefetch pc to check and possibly request

    output logic [1:0] proc2Imem_command, //controls request to Imem
    output logic [31:0] proc2Imem_addr, //address requested from Imem

    output logic [1:0][31:0] Icache_data_out, //value is memory[proc2Icache_addr]
    output logic [1:0] Icache_num_valid // when this is high 
);

    //create reques table 
    logic [15:0][31:0] request_table; //16 enties for every possible return response
    logic [15:0] request_valid; // valid bits for every memory tag 

    logic rejected_request;
    logic delayed_resett, sync_reset;
    logic prefetch_pc_is_in_cache;

    always_ff @(posedge clock) begin 
        // on reset invalidate all responses
        if(reset) begin  
            request_valid <= `SD 16'b0;
            rejected_request <= `SD 0; 
            sync_reset <= `SD 1;
        end 
        else begin 
            //got data/tag back from Imem, clear valid bit and forward data to cache
            if(Imem2proc_tag != 0 and request_valid[Imem2proc_tag]) begin 
                request_valid[Imem2proc_tag] <= `SD 0; 
            end 

            //put new request tag into table 
            if(Imem2proc_response != 0) begin 
                request_valid[Imem2proc_response] <= `SD 1; 
                request_table[Imem2proc_response] <= `SD proc2Imem_addr;
                rejected_request <= `SD 0; 
            end

            else begin 
                rejected_request <= `SD 1; 
            end 

            if(sync_reset)
                delayed_reset <= `SD 1;
            else 
                delayed_reset <= `SD 0; 

            sync_reseet <= `SD 0;
        end 
    end 

    //forward data to cache if memory returns something
    logic cache_write_enable;
    logic [63:0] cache_write_data;
    logic [31:0] cache_write_addr;

    assign cache_write_addr = request_table[Imem2proc_tag];
    assign cache_write_data = Imem2proc_data;
    assign cache_write_enable = (Imem2proc_tag != 0) & (rqueest_valid[Imem2proc_tag]);

    icache_mem cash_money(
        .clock(clock),
        .reset(reset),
        .pc({pc[31:2], 2'b0}),
        .write_enable(cache_write_enable),
        .write_addr(cache_write_addr),
        .write_data(cache_write_data),
        .prefetch_pc_check(prefetch_pc),
        .instr(Icache_data_out),
        .num_valid_instr(Icache_num_valid),
        .prefetch_pc_is_in_cache(prefetch_pc_is_in_cache)
    );

    //cam request table for potential requests
    logic pc_already_requested, prefetch_already_requested;
    always_comb begin 
        pc_already_requested = 0;
        prefetch_pc_already_requested = 0; 
        for(int i =0; i<16;i++) begin 
            if(request_valid[i] & request_table[i] == {pc[31:3],3'b0)) begin 
                pc_already_requested = 1; 
            end 

            if(request_valid[i] & request_table[i] == {prefetch_pc[31:3], 3'b0}))
                prefetch_already_requested = 1; 
        end
    end

    logic pc_send_request, prefetch_seend_request;
    assign pc_send_request = (Icache_num_valid == 0) & (!pc_already_requested);
    assign prefetch_send_request = (!prefetch_pc_is_in_cache) & (!prefetch_already_requested);

    always_comb begin 
        if(pc_send_request) begin 
            proc2Imem_command = BUS_LOAD:
            proc2Imem_addr = {pc[31:3], 3'b0};
        end 
        else if(prefetch_send_request) begin 
            proc2Imem_command = BUS_LOAD;
            proc2Imem_addr = {prefetch_pc[31:3], 3'b0};
        end 
        else begin 
            proc2Imem_command = BUS_NONE;
            proc2Imem_addr = 32'h0;
        end 
    end 
endmodule 