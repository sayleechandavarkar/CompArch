//How does the maptable work??
/* random thoughts and ideas
It takes in input from the cdb, dispatch, architected map table and free list 
for each cycle it is going to taking in the registers 
From dispatch it gets the destination registers cause 2 way superscalar
From cdb it gets the instruction that have been completed so you can use these to set the ready bit
we also need to give these tags back to the RS so that it can clear its entries

==> What does this mean now in terms of number of ports and number of entries
==> What happens on a mispredict 
==> What happens when its rewinding 

We have 6 read ports and 2 write ports 
6 read ports because RS needs rs1 rs2 and rd tags
2 write ports cause we need to take two ready tags from cdb


write enable comes from the dispatch stage
the first write enable = (num_to_dispatch!=0) && (decoded_inst[0].has_dst)
the second write enable = (num_to_dispactch==2) && (decoded_inst[1].has_dst)
so basically what we are doing is making sure that two instructions have been dispatched
first one is a check that there are insts to dispatch 
second one is a check that there are two insts to dispatch. It only makes sense to have a secodn enable if there is a second inst to dispatch 

write_data to the map table is basically TAG retired from rob and true -ready bit
copy_data_in basically is used to copy in the architected map table
copy_en comes in from the retiring misprediction signal from the dispacth stage

We have completing now cause we want to address the internal forwarding of the ready tags
because n entries will update entries after a cycle or half cycle and we can't let that happen
so we keep the tab of the ready coming in the */ 
//NVM the comments about completing_now stuff

module maptable #(
	READ_PORTS=6, WRITE_PORTS=2)(
	input reset, 
	input clock,
	input CDB_PACKET [1:0] cdb,
	input ARG [READ_PORTS-1:0] read,
	input logic [WRITE_PORTS-1:0] write,
	input logic [WRITE_PORTS-1:0] write_en,
	input TAG_AND_READY [WRITE_PORTS-1:0] write_data,
	input TAG_AND_READY [`NUM_AREGS-1:0] copy_data_in,
	input logic copy_en,
	
	output TAG_AND_READY [READ_PORTS-1:0] read_data,
	output TAG_AND_READY [`NUM-AREGS-1:0] copy_data_out
	);
	
	TAG_AND_READY [`NUM_AREGS-1:0] entries, n_entries;
	logic [`NUM_AREGS-1:0] completing_now;
	
	/*
	//read logic
	always_comb begin 
		completing_now = 0; 
		//skip r0 because of the error it causes?? 
			for(int i = 1; i < `NUM_AREGS; i++) begin 
				completing_now[i] = (cdb[0].tag == entries[i].tag || cdb[1].tag == entries[i].tag)	
			end 


		read_data = 0;
		for(int i = 0; i < `NUM_AREGS; i++) begin 
			for(int j = 0; j < READ_PORTS; j++) begin 
				if(read[j] == i) begin 
					read_data[j].tag = entries[i].tag;
					read_data[j].ready = entries[i].ready || completing_now[i];
				end
			end	
		end
	end

		
	//write_logic
	always_comb begin 
		n_entries = entries;
		// skip r0 can't be written
		for(int i = 1; i < `NUM_AREGS; i++) begin 
			n_entries[i].ready = entries[i].ready || completing_now[i];
			for( int j = 0; j < WRITE_PORTS; j++) begin 
				if(write[j] == i & write_en[j]) begin 
					n_entries[i] = write_data[j];
				end
			end
		end
	end


	//for copying
	assign copy_data_out = n_entries;
	
	always_ff@(posedge clock) begin
		if(reset) begin 
			for(int i=0; i<`NUM_AREGS; i++) begin 
				entries[i].tag <= `SD i;
				entries[i].ready <= `SD `TRUE;
			end
		end
		else if(copy_en) begin 
			entries <= `SD copy_data_in;
		end
		else begin 
			entries <= `SD n_entries;
		end

	end

	*/

	//REMOVED ONE LOOP AND QUEUE TO KEEP TRACK 
	//logic for copying in data
	always_ff @(posedge clock) begin 
		if(reset) begin 
			for(int i = 0; i < `NUM_AREGS; i++) begin 
				entries[i].tag <= `SD i;
				entries[i].ready <= `SD `TRUE;
			end	
		else if(copy_en) begin 
			entries <= `SD copy_data_in;
		end else begin 	
				entries[i] <= ` SD n_entries[i];
		end
	end

	//Write Logic
	always_comb begin 
	n_entries = entries;
	//skip r0 cause you cannot write it
		for(int i = 1; i < `NUM_AREGS; i++ ) begin
				n_entries[i].ready = entries[i].ready || entries[i].tag == cdb[0].tag || entries[i].tag == cdb[1].tag; 
				for(int j = 0; j < WRITE_PORTS; j++) begin 
					if(write[j] == i && write_en[j]) begin 
						n_entries[i] = write_data[j];
					end
				end
		end
	
	end

	//read logic 
	always_comb begin 
		//skip r0 cause whats the point anyway
		for(int i = 1; i < `NUM_AREGS; i++) begin 
			for(int j = 0; j < READ_PORTS; j++) begin 
				if(read[j] == i) begin 
					read_data[j] = n_entries[i];
				end
			end
		end
	end

endmodule
