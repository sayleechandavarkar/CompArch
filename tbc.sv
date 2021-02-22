module tbc(
    input clock,
    input reset,
    input [1:0] [`XLEN-1:0] inst_pc,
    input CDB_PACKET branch_packet,
    output BRANCH_PREDICTION [1:0] predicted_branch
);

    parameter NUM_TBC_TAG_BITS = 6;

    BRANCH_PREDICTION [(2**NUM_TBC_TAG_BITS)-1:0] prediction;
    logic [(2**NUM_TBC_TAG_BITS)-1:0] bht_pc;
    logic [NUM_TBC_TAG_BITS-1:0] inst_0_idx, inst_1_idx, branch_pc_idx;
    
    BRANCH PREDICTION prediction, n_prediction;
    logic br_taken;

    assign inst_1_idx = inst_pc[1][NUM_TBC_TAG_BITS+1:2];
    assign inst_0_idx = inst_pc[0][NUM_TBC_TAG_BITS+1:2];

    //ROB stuff
    assign branch_pc_idx = branch_packet.pc[NUM_TBC_TAG_BITS+1:2];
    assign br_taken = branch_packet.taken_branch;

    //output logic
    assign predicted_branch[1] = predictions[inst_1_idx];
    assign predicted_branch[0] = predictions[inst_0_idx];

    assign prediction = predictions[branch_pc_idx];

    always_comb begin 
        case(prediction) 
            STRONGLY_NOT_TAKEN: begin 
                n_prediction = br_taken ? WEAKLY_NOT_TAKEN : STRONGLY_NOT_TAKEN;
            end
            WEAKLY_NOT_TAKEN: begin 
                n_prediction = br_taken ? WEAKLY_TAKEN : STRONGLY_NOT_TAKEN;
            end
            WEAKLY_TAKEN begin 
                n_prediction = br_taken ? STRONGLY_TAKEN : WEAKLY_NOT_TAKEN;
            end
            STRONGLY_TAKEN begin 
                n_prediction = br_taken ? STRONGLY_TAKEN : WEAKLY_TAKEN;
            end
        endcase
    end

    always_ff @(posedge clock) begin 
        if(reset) begin
            //initial state strongly not taken for all entries 
            predictions <= `SD {(2**NUM_TBC_TAG_BITS){STRONGLY_NOT_TAKEN}};
        end else begin
            if(branch_packet.is_branch) begin 
                predictions[branch_pc_idx] <= `SD n_prediction;
            end
        end
    end

endmodule
