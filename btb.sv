module btb(
    input clock,
    input reset,
    input [1:0] [`XLEN-1:0] inst_pc,
    input CDB_PACKET branch_packet,
    output [1:0] [`XLEN-1:0] target_pc
    output [1:0] target_pc_valid
);

//parameter for number of bits from pc that are used to index into btb
parameter NUM_BTB_TAG_BITS = 6;

//Keep track of both branch PC and target PC
//2**NUM_BTB_TAG_BITS entries in the BTB

logic [(2**NUM_BTB_TAG_BITS)-1:0] [`XLEN-1:0] btb_pc, btb_target_pc;
logic [(2**NUM_BTB_TAG_BITS)-1:0] btb_valid;
logic [NUM_BTB_TAG_BITS-1:0] inst_0_idx, inst_1_idx, ret_inst_0_idx, ret_inst_1_idx, branch_pc_idx;

assign inst_1_idx = inst_pc[1][NUM_BTB_TAG_BITS+1:2];
assign inst_0_idx = inst_pc[0][NUM_BTB_TAG_BITS+1:2];

assign target_pc[1] = btb_target_pc[inst_1_idx];
assign target_pc[0] = btb_target_pc[inst_0_idx];

assign target_pc_valid[1] = btb_valid[inst_1_idx] & (inst_pc[1] == btb_pc[inst_1_idx]);
assign target_pc_valid[0] = btb_valid[inst_0_idx] & (inst_pc[0] == btb_pc[inst_0_idx]);

assign branch_pc_idx = branch_packet.pc[NUM_BTB_TAG_BITS+1:2];

always_ff @(posedge clock) begin 
    if(reset) begin 
        btb_pc <= `SD 0;
        btb_target_pc <= `SD 0;
        btb_valid <= `SD 0;
    end else begin
        if(taken_branch) begin 
            btb_pc[branch_pc_idx] <= `SD branch_packet.pc;
            btb_target_pc[branch_pc_idx] <= `SD branch_packet.branch_target;
            btb_valid[branch_pc_idx] <= `SD `TRUE;
        end
        //misprediction
        if(branch_packet.misprediction && !branch_packet.taken_branch) begin
            btb_pc[branch_pc_idx] <= `SD 32'h0;
            btb_target_pc[branch_pc_idx] <= `SD 32'h0;
            btb_valid[branch_pc_idx] <= `SD `FALSE;
        end
    end 

/* So basically what we are doing is getting a packet from the execute stage. So if the branch was taken then you update the pc, branch target etc
if it was a mispredict then you indicate accordingly by adding zeros for that entry in the btb
*/

