typedef enum logic [2:0] {
    IDLE,
    LOAD_INIT,
    STORE_INIT,
    LOAD_MISS,
    STORE_MISS,
    EVICTING,
    FLUSH,
    REFUSED_REQ,
} CACHE_STATE;

module dcache_controller(
    input clock,
    input reset, 
    
    //these are from memory 
    input [3:0] Dmem2proc_response, // 0 is a rejected request
    input [63:0] Dmem2proc_data, // single block o finstr back from mem
    input [3:0] Dmem2proc_tag, // request number for return data, 0 is nothing
    input program_finished,

    //from processor
    input [1:0] proc2Dcache_command, //controls request to Imem
    input [31:0] proc2Dcache_addr,
    input [31:0] proc2Dcache_data,
    input MEM_SIZE proc2mem_size,

    //to processor
    output logic Dcache_accepting_reqs,
    output logic [31:0] Dcache_data_out,
    output logic Dcache_num_valid,
    output logic finished

);

    logic wr_en, proc2Dcache_block_offset, rd_valid, evicted_block_is_dirty, latched_evicted_block_is_dirty;
    logic write_hit;
    logic write_dirty_unenable, write_dirty_enable;
    logic [63:0] wr_hit_block;
    logic [2:0] proc2Dcache_set, evicted_set, latched_evicted_set;
    logic [25:0] proc2Dcache_tag, evicted_tag, latched_evicted_tag;
    logic [31:0] rd_data;
    logic [63:0] evicted_block, wr_data, latched_evicted_block;
    logic dirty_search;
    logic read_dirty;
    logic [1:0] way_selected;
    CACHE_STAE state, n_state;

    logic [31:0] current_addr, current_data;
    logic [3:0] outstanding_req_tag;
    MEM_SIZE current_size;


    //for repeating refused requests
    logic [1:0] latched_Dcache2Dmem_command;
    logic [31:0] latched_Dcache2Dmem_addr;
    logic [63:0] latched_Dcache2Dmem_data;
    CACHE_SATE latched_n_state;

    logic [4:0] flush_set_way_ctr;
    logic [7:0] mask_bits;
    assign proc2Dcache_block_offset = current_addr[2];
    assign proc2Dcache_tag = current_addr[31:6];
    assign proc2Dcache_set = (state == FLUSH)? flush_set_way_ctr[2:0] : current_addr[5:3];

    wire mem_valid = Dmem2proc_tag != 0 & Dmem2proc_tag == outstanding_req_tag;

    always_ff @(posedge clock) begin 
        if(reset) begin 
            state <= IDLE;
            latched_evicted_block_is_dirty <= `SD  0; 
            latched_evicted_block <= `SD 0; 
            latched_evicted_tag <= `SD 0; 
            latched_evicted_set <= `SD 0; 
            outstanding_req_tag <= `SD 0; 
            flush_set_way_ctr <= `SD 0;
        end 
        else begin 
            if(Dcache_accepting_reqs) begin 
                current_size <= `SD proc2mem_size;
                current_addr <= `SD {16'b0, proc2Dcache_addr[15:0]}; //don't allow invalid addresses
                current_data <= `SD proc2Dcache_data;
            end

            if(Dcache2Dmem_command != BUS_NONE & Dmem2proc_response == 4'b0) begin 
                state <= `SD REFUSED_REQ;
            end else begin 
                state <= `SD n_state; 
            end 

            //latch dirty data suff because timing ..
            latched_evicted_block_is_dirty <= `SD evicted_block_os_dirty; 
            latched_evicted_block <= `SD evicted_block;
            latched_evicted_tag <= `SD evicted_tag;
            latched_evicted_set <= `SD evicted_set;

            if(Dcache2Dmem_command != BUS_NONE) begin 
                outstanding_req_tag <= `SD Dmem2proc_response;
            else if(mem_valid) begin 
                oustanding_req_tag <= `SD 4'b0;
            end 

            if(state != REFUSED_REQ) begin 
                latched_Dcache2Dmem_command <= `SD Dcache2Dmem_command;
                latched_Dcache2Dmem_addr <= `SD Dcache2Dmem_addr;
                latched_Dcache2Dmem_data <= `SD Dcache2Dmem_data;
                latched_n_state <= `SD n_state;
            end

            if(state == FLUSH) begin 
                flush_set_way_ctr <= `SD flush_set_way_ctr + 1;
            end
            finished <= `SD (flushh_set_way_ctr == 5'h1F);
            end 
        end

        // two possibilities data from cache on hi or from memory on miss
        assign Dcache_num_valid = (state == LOAD_INIT & rd_valid)
                                | (state == LOAD_MISS & mem_valid);

        wire [31:0] raw_data = (state == LOAD_INIT) ? rd_data :
                                current_addr[2] ? Dmem2proc_data[63:32] : Dmem2proc_data[31:0];

        wire [31:0] shifted_raw_data = raw_data >> 8*(current_addr[1:0]);
        
        always_comb begin 
            case(current_size) 
                WORD: Dcache_data_out = shifted_raw_data;
                HALF: Dcache_data_out = {16'b0, shifted_raw_data[15:0]};
                BYTE: Dcache_data_ou = {24'b0, shifted_raw_data[7:0]};
                default: Dcache_data_out = shifted_raw_data;
            endcase 
        end 

        wire [63:0] old_data = (state == STATE_INIT & write_hit) ? write_hit_block: Dmem2proc_data;
        wire [63:0] new_data = current_data << 8*current_addr[2:0];

        always_comb begin 
            // if this is a load miss, we are just copying from memory
            // otherwise its a store and we need to mix in the store data
            if(state != LOAD_MISS) begin 
                case(current_size) 
                    WORD: mask_bits = 8'b0000_1111 << current_addr[2:0];
                    HALF: mask_bits = 8'b0000_0011 << current_addr[2:0];
                    BYTE: mask_bits = 8'b0000_0001 << current_addr[2:0];
                endcase 
            end 

            for(int i = 0; i< 8; i++) begin 
                if(mask_bits[i]) begin 
                    wr_data[[(i*8)+7 -: 8] = new_data[(i*8)+7 -: 8];
                end else begin 
                    wr_data[(i*8)+7 -: 8] = old_data[(i*8)+7 -: 8];
                end 
            end

        end 

        always_comb begin 
            case(state)
                STORE_INIT: begin 
                    wr_en = write_hit; //store if cache hit
                    write_dirty_enable = 1;
                    write_dirty_unenable = 0; 
                end 
                LOAD_MISS: begin 
                    wr_en = mem_valid; 
                    write_dirty_enable = 0; 
                    write_dirty_unenable = 1; 
                end
                STORE_MISS: begin 
                    wr_en = mem_valid; 
                    write_dirty_enable = 1; 
                    write_dirty_unenable = 0;
                default: begin 
                    wr_en = `FALSE;
                    write_dirty_enable = 0; 
                    write_dirty_unenable = 0;
                end
            endcase 
        end




    //**********MEMORY INTERACTIONS *******//
    always_comb begin 
        case(state)
            EVICTING: Dcache2Dmem_addr = {latched_evicted_tag, latched_evicted_set, 3'b0};
            FLUSH: Dcache2Dmem_addr = {evicted_tag, evicted_set, 3'b0};
            REFUSED_REQ: Dcache2Dmem_addr = latched_Dcache2Dmem_addr;
            default: Dcache2Dem_addr = {current_addr[31:3], 3'b0};
        endcase 
    end 

    always_comb begin 
        case(state)
            FLUSH: Dcache2Dmem_data = evicted_block;
            REFUSED_REQ: Dcache2Dmem_data = latched_Dcache2Dmem_data;
            default: Dcache2Dmem_data = latched_evicted_block;
        endcase
    end 

    always_comb begin 
        case(state)
            LOAD_INIT: Dcache2Dmem_command = rd_valid ? BUS_NONE : BUS_LOAD;
            STORE_INIT: Dcache2Dmem_command = write_hit ? BUS_NONE : BUS_LOAD;
            EVICTING: Dcache2Dmem_command = latched_evicted_block_is_dirty ? BUS_STORE : BUS_NONE;
            FLUSH: Dcache2Dmem_command = read_dirty ? BUS_STORE : BUS_NONE;
            REFUSED_REQ: Dcache2Dmem_command = latched_Dcache2Dmem_command; 
            default: Dcache2Dmem_command = BUS_NONE;
        endcase 
    end 

    //flush stuff 
    assign dirty_search = (state == FLUSH);
    assign way_selected = flush_set_way_ctr[4:3];

    CACHE_STATE accept_req_state;
    // set n_state and accepting reqs
    always_comb begin 
        n_state = state; 
        Dcache_accepting_reqs = `FALSE;

        case(proc2Dcache_command)
            BUS_LOAD: accept_req_state = LOAD_INIT;
            BUS_STORE: accept_req_state = STORE_INIT;
            default: accept_req_state = program_finished ? FLUSH : IDLE;
        endcase 

        case(state) 
            IDLE: begin 
                Dcache_accepting_reqs = `TRUE;
                n_state = accept_req_state; 
            end 
            LOAD_INIT: begin 
                if(rd_valid) begin 
                    Dcache_accepting_reqs = `TRUE;
                    n_state = accept_req_state;
                end else begin 
                    n_state = LOAD_MISS;
                end 
            end
            STORE_INIT: begin 
                if(write_hit) begin 
                    Dcache_accepting_reqs = `TRUE;
                    n_state = accept_req_state;
                end else begin 
                    n_state = STORE_MISS;
                end 
            end
            LOAD_MISS: begin 
                if(mem_valid) begin  
                    n_state = EVICTING;
                end else begin
                    n_state = LOAD_MISS;
                end
            end
            STORE_MISS: begin 
                if(mem_valid) begin
                    n_state = EVICTING;
                end else begin 
                    n_state = STORE_MISS;
                end
            end 
            EVICTING: begin 
                Dcache_accepting_reqs = `TRUE;
                n_state = accept_req_state;
            end
            FLUSH: begin 
                n_state = FLUSH;
            end 
            REFUSED_REQ: begin 
                n_state = latched_n_state;
            end 
        endcase
    end 



