module cache(
    input clock, 
    input reset, 
    input wr1_en, 
    input read_block_offset,
    input [2:0] wr1_set_idx, rd1_set_idx,
    input [25:0] wr1_tag, rd1_tag,
    input [63:0] wr1_data,
    input dirty_en, 
    input dirty_unen,
    input dirty_search, //search through the while cache, return the dirty block
    input [2:0] way_selected,

    output logic [31:0] rd1_data,
    output logic rd1_valid, 
    output logic write_hit, 
    output logic [1:0] wr_hit_way, 
    output logic [63:0] wr_hit_block,

    output logics write_dirty,
    output logic read_dirty,
    output logic [25:0] dirty_tag,
    output logic [2:0] dirty_idx,
    output logic [63:0] dirty_block,
);

    logic [7:0] [63:0] data [3:0];
    logic [7:0] [25:0] tags [3:0];
    logic [7:0] valids [3:0];
    logic [7:0] dirty [3:0];
    logic [63:0] cam_data;
    logic [1:0] mru [7:0];
    logic [1:0] nmru [7:0];
    logic read_valid;
    logic [1:0] hit_way;
    logic [1:0] counter;
    logic [1:0] next_num;
    logic [1:0] selected_way;
        

    always_comb begin 
        if(dirty_search) begin 
            read_dirty  = dirty[way_selected][rd1_set_idx]; //check if the block being read is dirty
            dirty_block =  data[way_selected][rd1_set_idx]; //get the dirty data
            dirty_tag   = tags[way_selected][rd1_set_idx]; // get  the tag associated with the dirty data
            dirty_idx   = rd1_set_idx;
            write_dirty = dirty[selected_way][wr1_set_idx]; 
        end else begin 
            read_dirty  = dirty[way_selected][rd1_set_idx];
            write_dirty = dirty[selected_way][wr1_set_idx];
            dirty_tag   = tags[selected_way][wr1_set_idx];
            dirty_block = data[selected_way][wr1_set_idx];
            dirty_idx   = wr1_set_idx;
        end 
    end

    // get the incoming data and set the incoming tags and valid bits
    always_ff @(posedge clock begin 
        if(reset) begin 
            for(int i=0;i<4;i++) begin 
                for(int j=0;j<8;j++) begin 
                    data[i][j] <= `SD 64'b0;
                    tags[i][j] <= `SD 28'b0;
                    valids[i][j] <= `SD 0; 
                end 
            end 
        end else if(wr1_en) begin 
                tags[selected_way][wr1_set_idx] <= `SD wr1_tag;
                data[selected_way][wr1_set_idx] <= `SD wr1_data;
                valids[selected_way][wr1_set_idx] <= `SD 1'b1;
        end
    end

    // enable and disable the dirty bits
    always_ff @(posedge block) begin 
        if(reset) begin
            for(int i=0;i<4;i++) begin 
                for(int j=0;j<8;j++) begin 
                    dirty[i][j] <= `SD 0; 
                end 
            end 
        end else if(dirty_en & wr1_en) begin 
                dirty[selected_way][wr1_set_idx] <= `SD 1'b1;
        end else if(dirty_unen & wr1_en) begin 
                dirty[selected_way][wr1_set_idx] <= `SD 1'b0;
        end 
    end 

    //replacement policy - MRU
    always_ff @(posedge clock) begin 
        if(reset) begin 
            for(int i=0;i<8;i++) begin 
                mru[i] <= `SD 2'b00;
            end 
        end else if(wr_en) begin 
            mru[wr1_set_idx] <= `SD selected_way;
        end else if(read_valid) begin 
            mru[rd1_set_idx] <= `SD hit_way;
        end 
    end 

    //READ CAM
    always_comb begin 
        rd1_valid = 1'b0; 
        cam_data = 63'b0; 
        hit_way = 0; 
        for(int i=0;i<4;i++) begin 
            if((tags[i][rd1_set_idx] == rd1_tag) && valid[i][rd1_set_idx]) begin  
                    rd1_valid = 1'b1;
                    cam_data  = data[i][rd1_set_idx];
                    hit_way   = i;
            end 
        end       
    end 

    //write hit
    always_comb begin 
        write_hit    = 1'b0;
        wr_hit_way   = 1'b0; 
        wr_hit_block = 63'b0;
        for(int i=0;i<4;i++) begin 
            if((tags[i][wr1_set_idx] == wr1_tag) && valids[i][wr1_set_idx]) begin 
                write_hit  = 1'b1;
                wr_hit_way = i;
                wr_hit_block = data[i][wr1_set_idx];
            end
        end 
    end 

    //counter 
    always_ff @(posedge clock) begin 
        if(reset) begin 
            counter <= `SD 0; 
        end else begin 
            counter <= `SD counter + 1;
        end
    end

    //psuedo random logic, convert most recently used to NMRU
    //even if there is over flow we dont care for the case of 11 it would go to 00
    always_comb begin 
        for(int i=0;i<8;i++) begin
            nmru[i] = (counter == mru[i])? (mru[i] + 1): counter;
        end 
    end 

    //logic for selecting the address thats going to be writen into
    always_comb begin 
        if(write_hit) begin 
            selected_way = wr_hit_way;
        end else begin 
            selected_way = nmru[wr1_set_idx];
        end
    end 

    //logic [31:0] rd_data
    assign rd1_data   = read_block_offset? cam_data[63:32] : cam_data[31:0];
    assign read_valid = rd1_valid;

endmodule



                



/*
so there are 5 parts to Dcache mem
1) create an internal data structure, tag and valid bits structure 
    if the reset all the above three structures are 0
    else  if there is a write_en to the said set add it to the 
    respective structures and set the corresponding valid bits

2) Keep track of the dirty bits and whatnot
    if the dirty signal from the controlller has been enabled then 
    for the said idx set those bits. Reset the said bits if the 
    dirty signal is deasserted. Dirty bits are associated with the 
    writing process

3) Have a Read and Write Cam that give out the read hit and write hit data
    the CAM works by comparing the corresponding provided read and write tags
    and that the said blocks are valid
    for ex. for read cam if the tags match and it is valid data
            you store the hit_way. Assert that the read was a hit 
            and give out the corresponding data

            for write cam if the tags match and it is valid data
            you store the hit_way. Assert that the write was a hit and 
            give out the corresponding data. Not sure if giving out data is right or needed 
            any sense. Instead it is done directly at the second point mentioned above

4) Keep Track of the MRU block and generate a psuedo random logic for line replacement
    So Whether we are reading or writing to the block we keep track of the MRU
    so if it was read hit. Then that read hit way is the MRU for that read_set_idx
    and if it was write hit. Then that write hit way is the MRU for that write_set_idx
    
    from the MRU block use some sort of Psuedo random logic to create NMRU
    so first thing is you have a counter runnning. if the MRU for a set is not equal to the counter 
    then set the NMRU equal to the counter. If by chance the MRU is equal to the counter then 
    if A0 is MRU then choose A1 as NMRU. if A1 is MRU use A2 as NMRU so and so forth 

5) When its a write hit the selected way is the one that is 

first its a write back cache so keep track of the dirty data


*/

/*

first step take the data tag and validate it

always_ff @(posedge clock) begin 
    if(reset) begin 
        for(int i=;i<4;i++) begin 
            for(int j=0;j<8;j++) begin 
                data[i][j]   <= `SD 0;
                tags[i][j]   <= `SD 0;
                valids[i][j] <= `SD 0;
            end
        end 
    end else if(wr1_en) begin 
           data[selected_way][wr1_set_idx] <= `SD wr_data;
           tags[selected_way][wr1_set_idx] <= `SD wr_tag;
           valids[selected_way][wr1_set_idx] <= `SD 1'b1;
    end
end

//check if its a read hit
always_comb begin 
    rd1_valid = 0; 
    hit_way = 2'b0;
    cam_data = 64'b0;
    for(int i=0;i<4;i++) begin 
        if((tags[i][rd1_set_idx] == rd1_tag) && valids[i][rd1_set_idx]) begin 
            rd1_valid = 1; 
            hit_way = i;
            cam_data = data[i][rd1_set_idx];
        end
    end 
end 

//check if its a write_hit
always_comb begin 
    wr_hit_way = 2'b0;
    write_hit = 0; 
    wr_hit_block = 64'b0;
    for(int i=0;i<4;i++) begin 
        if((tags[i][wr1_set_idx] == wr1_tag) && valids[i]) begin 
            write_hit    = 1;
            wr_hit_block = data[i][wr1_set_idx];
            wr_hit_way   = i;
        end 
    end 

//update the dirty bits
always_ff @(posedge clock) begin 
    if(reset) begin
        for(int i=0;i<4;i++) begin
            for(int j=0;j<8;j++) begin  
                dirty[i][j] <= `SD 0; 
            end 
        end
    end else if(dirty_en) begin 
            dirty[selected_way][wr1_set_idx] <= `SD 1'b1;
    end else if(dirty_unen) begin 
            dirty[selected_way][wr1_set_idx] <= `SD 1'b0;
        end 
end 

//BLOCK REPLACEMNT POLICY MRU
always_ff @(posedge clock) begin 
    if(reset) begin 
        for(int i=0;i<8;i++) begin 
            mru[i] <= `SD 0;
        end
    end else if(write_hit) begin 
            mru[i] <= `SD selected_way;
    end else if(read_valid) begin
            mru[i] <= `SD hit_way;
    end 
end

always_ff @(posedge clock) begin 
    if(reset) begin 
        counter <= 0; 
    end else 
        counter <= counter + 1;
    end 
end

always_comb begin 
    for(int i=0;i<8;i++) begin 
        nmru[i] = (counter == mru[i])? mru[i] + 1: counter;
    end    
end

always_comb begin 
    if(write_hit) begin 
        selected_way = wr_hit_way;
    end 
        selected_way = nmru[wr1_set_idx];
end

always_comb begin 
    if(dirty_search) begin 
        read_dirty  = dirty[way_selected][rd1_set_idx];
        write_dirty = dirty[selected_way][wr1_set_idx];
        dirty_data  = data[way_selected][rd1_set_idx];
        dirty_tag   = tags[way_selected][rd1_set_idx];
        dirty_idx   = rd1_set_idx; 
    end else begin 
        read_dirty  = dirty[way_selected][rd1_set_idx];
        write_dirty = dirty[selected_way][wr1_set_idx];
        dirty_data  = data[selected_way][wr1_set_idx];
        dirty_tag   = tags[selected_way][wr1_set_idx];
        dirty_idx   = wr1_set_idx;
    end 
end 











*/