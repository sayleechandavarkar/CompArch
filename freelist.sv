//Some thoughts and ideas about the working of the freelist 
so it outputs two free pregs number. These are passed on to the ROB, RS and maptable
How does the free list give out the free pregs??
All the PREGS are free first. 
you can't just free PREG when the insn retires cause we don't we have a arch reg to copy it to
so free PREGS previously mapped to same logical register
So how do you know previously mapped PREG
What happens on rewind??

module free_list #(
    FREE_PORTS=2) (
    input reset, 
    input clock,
    input PREG [FREE_PORTS-1:0] preg_to_free,
    input [FREE_PORTS-1:0] free_en,
    input [1:0] num_to_claim,
    output PREG [1:0] preg_to_claim
    );

    logic [`NUM_PREGS-1:0] avail_bitvector, n_avail, avail_now, avail_now_rev, gnt_1, gnt_2, gnt_2_rev;
    logic [1:0] req_ups;

    
    ps #(`NUM_PREGS) ps1(
        .en(1'b1),
        .req(avail_now),
        .req_up(req_ups[0]),
        .gnt(gnt_1)
    );

    ps #(`NUM_PREGS) ps2(
        .en(1'b1),
        .req(avail_now_rev),
        .req_up(req_ups[1]),
        .gnt(gnt_2_rev)
    );

    pe #(6) pe1(
        .gnt(gnt_1),
        .enc(preg_to_claim[0])
    );

    pe #(6) pe2(
        .gnt(gnt_2),
        .enc(preg_to_claim[1])
    );

    always_comb begin 
        avail_now = avail_bitvector;
        for(int i = 0; i < FREE_PORTS; i++) begin 
            if(free_en[i]) begin 
                avail_now[preg_to_free[i]] = 1;
            end
        end

            //never allow p0 to be returned
            avail_now[0] = 1'b0;

            //reverse input/output to second ps
            for(int i = 0; i < `NUM_PREGS; i++) begin 
                avail_now_rev[i] = avail_now[`NUM_PREGS - 1 -i];
                gnt_2[i] = gnt_2_rev[`NUM_PREGS - 1 -i];
            end

           n_avail = (num_to_claim == 2) ? avail_now & ~gnt_1 & ~gnt_2 : (num_to_claim != 0) ? avail_now & ~gnt_1 : avail_now;
    end

    always_ff @(posedge clock) begin
                if(reset) begin 
                    //start with the pregs corresponding to aregs in use
                    avail_bitvector <= `SD {{(`NUM_PREGS-`NUM_AREGS){1'b1}},{`NUM_AREGS{1'b0}}};
                end
                else begin 
                    avail_bitvector <= `SD n_avail;
                end
    end   



//What we are essentially doing is basically taking one from the top and one from the bottom. Using set of selectors and the encoders to free the pregs
/* We use the priority selectors to select the PREGS from the list of available PREGS
We are using two priority selectors first PS gives us the top PREG. For the second PS we are passing the reversed avail list
By doing this it lets us select two PREGS one from top and the other from the bottom
We pass the o/p of the first PS to a PE and the reversed o/p of the second PS to PE.
By passing the o/ps to the PEs what we are doing basically selecting the top from the first half and top from the second half

now in the combinational logic we update the avail_now list based on the pregs_to_free input to the module. 
We use this recently freed pregs to update the n_avail. 
n_avail can be easily be decided, its based on whats avail_now and whatever we have granted now. So whatever was already available minus whatever has been granted. Note we aren't literally subtracting

Use this n_avail and avail_bitvector we pass through using sequential logic to the combinational logic  


*/