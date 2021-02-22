module class_data();

//class with local fields
class Packet;
    int address;
    bit [63:0] data;
    shortint crc;
endclass: Packet

//Class with task
class print; 
    task print_io (input string msg);
        $display("%s",msg);
    endtask: print_io
endclass: print

//create instance 
    //alloccate memory 
    p = new();
    prn = new();
    //assign values 
    p.address = 32'hDEAD_BEEAF;
    p.data = {4{16'h55AA}};
    p.crc = 0;
    //print all the assigned values 
    $display("p.address = %d p.data = %h p.crc = %d",p.address,p.data, p.crc);
    prn.print_io("Test calling task inside class");
    $finish;
end 
endmodule 

//casting 
module casting_data();

int a = 0;
shortint b = 0;

initial begin 
    $monitor ("%g a = %d b = %h", $time, a, b);
    #1 a = int'(2.3*3.3);
    #1 b = shprtint'{8'hDE, 8'hAD, 8'hBE, 8'hEF};
    #1 $finish;
end 

endmodule

//arrays
/*SV uses the term packed array to refer to the dimensions declared before the object name. 
The term unpacked array is used to refer to the dimensions after the objectt na,e 

Dynamic arrays
new[]: This operator is used to set or change the size of the array 
size(): This method returns the current siz of the array
delete(): This method clears all the elements yielding an empty array

module dynamic_array_datta();

reg [7:0] mem[];

initial begin 
    $display("setting array size to 4");
    mem = new[4];
    $display("Initial array with default valus");
    for(int i=0;i<4;i++) begin 
        mem[i] = i;
    end 
    //doubling the size of array with old content still valid 
    mem = new[8](mem);
    mem = new[8](mem);
    //print current size
    $display("current array size %d", mem.size());
    for(int i=0;i<4;i++) begin 
        $display("value at location %g is %d", i, mem[i]);
    end 
    //delete array
    $display("Deleting the array");
    mem.delete();
    $display("current array size is %d",mem.size());
    #1 $finish;
end 
endmodule 