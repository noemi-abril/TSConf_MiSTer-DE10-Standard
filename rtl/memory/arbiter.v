
// PentEvo project (c) NedoPC 2008-2011
//
// DRAM arbiter. Shares DRAM between CPU, video data fetcher and other devices
//

// Arbitration is made on full 8-cycle access blocks. Each cycle is defined by dram.v and consists of 4 fpga clocks.
// During each access block, there can be either no videodata access, 1 videodata access, 2, 4 or 8 accesses.
// All spare cycles can be used by CPU or other devices. If no device uses memory in the given cycle, refresh cycle is performed.
//
// In each access block, videodata accesses are spreaded all over the block so that CPU receives cycle
// as fast as possible, until there is absolute need to fetch remaining video data.
//
// Examples:
//
// |                 access block                  | 4 video accesses during block, no processor accesses. video accesses are done
// | vid | vid | vid | vid | ref | ref | ref | ref | as soon as possible, spare cycles are refresh ones
//
// |                 access block                  | 4 video accesses during block, processor requests access every other cycle
// | vid | prc | vid | prc | vid | prc | vid | prc |
//
// |                 access block                  | 4 video accesses, processor begins requesting cycles continously from second one
// | vid | prc | prc | prc | prc | vid | vid | vid | so it is given cycles while there is such possibility. after that processor
//                                                   can't access mem until the end of access block and stalls
//
// |                 access block                  | 8 video accesses, processor stalls, if it is requesting cycles
// | vid | vid | vid | vid | vid | vid | vid | vid |
//
// |                 access block                  | 2 video accesses, single processor request, other cycles are refresh ones
// | vid | vid | ref | ref | cpu | ref | ref | ref |
//
// |                 access block                  | 4 video accesses, single processor request, other cycles are refresh ones
// | vid | vid | cpu | vid | vid | ref | ref | ref |
//
// access block begins at any dram cycle, then blocks go back-to-back
//
// key signals are go and XXX_req, sampled at the end of each dram cycle. Must be set to the module at c3 clock cycle.

// CPU can have either normal or lower access priority to the DRAM.
// At the INT active (32 of 3.5MHz clocks) the priority is raised to normal, so that CPU won't miss its interrupt.
// This should be considered if dummy RAM access used for waiting for the end of DMA operation instead of status bit polling.
//
// DRAM access priority:
// Z80 normal       Z80 low
// - VIDEO          - VIDEO
// - CPU            - TS
// - TM             - TM
// - TS             - DMA
// - DMA            - CPU


module arbiter
(

	input         clk,
	input         c0,
	input         c1,
	input         c2,
	input         c3,

	// dram.v interface
	output [20:0] dram_addr,   // address for dram access
	output        dram_req,    // dram request
	output        dram_rnw,    // Read-NotWrite
	output [ 1:0] dram_bsel,   // byte select: bsel[1] for wrdata[15:8], bsel[0] for wrdata[7:0]
	output [15:0] dram_wrdata, // data to be written

	// video
	input [20:0] video_addr,   // during access block, only when video_strobe==1
	input        go, 				// start video access blocks
	input [ 4:0] video_bw,		// [4:3] - total cycles: 11 = 8 / 01 = 4 / 00 = 2
										// [2:0] - need cycles
	output       video_pre_next,		// (c1)
	output       video_next,		  	// (c2) at this signal video_addr may be changed; it is one clock leading the video_strobe
	output       video_strobe, 	   // (c3) one-cycle strobe meaning that video_data is available
	output       video_next_strobe, 	// (c3) one-cycle strobe meaning that video_data is available
	output       next_vid,		    	// used for TM prefetch

	// CPU
	input [20:0] cpu_addr,
	input [ 7:0] cpu_wrdata,
	input        cpu_req,
	input        cpu_rnw,
	input        cpu_wrbsel,
	output reg   cpu_next,		// next cycle is allowed to be used by CPU
	output reg   cpu_strobe,	// c2 strobe
	output reg   cpu_latch,		// c2-c3 strobe
	output       curr_cpu_o,
	// DMA
	input [20:0] dma_addr,
	input [15:0] dma_wrdata,
	input        dma_req,
	input        dma_rnw,
	output       dma_next,

	// TS
	input [20:0] ts_addr,
	input        ts_req,
	output       ts_pre_next,
	output       ts_next,

	// TM
	input [20:0] tm_addr,
	input	       tm_req,
	output       tm_next
);

assign curr_cpu_o = curr_cpu;

localparam CYCLES    = 5;

localparam CYC_CPU   = 5'b00001;
localparam CYC_VID   = 5'b00010;
localparam CYC_TS    = 5'b00100;
localparam CYC_TM    = 5'b01000;
localparam CYC_DMA   = 5'b10000;
localparam CYC_FREE  = 5'b00000;

localparam CPU   = 0;
localparam VIDEO = 1;
localparam TS    = 2;
localparam TM    = 3;
localparam DMA   = 4;

reg [CYCLES-1:0] curr_cycle; // type of the cycle in progress
reg [CYCLES-1:0] next_cycle; // type of the next cycle

wire next_cpu = next_cycle[CPU];
assign next_vid = next_cycle[VIDEO];
wire next_ts  = next_cycle[TS];
wire next_tm  = next_cycle[TM];
wire next_dma = next_cycle[DMA];

wire curr_cpu = curr_cycle[CPU];
wire curr_vid = curr_cycle[VIDEO];
wire curr_ts  = curr_cycle[TS];
wire curr_tm  = curr_cycle[TM];
wire curr_dma = curr_cycle[DMA];


// track blk_rem counter:
// how many cycles left to the end of block (7..0)
wire [2:0] blk_nrem = (video_start && go) ? {video_bw[4:3], 1'b1} : (video_start ? 3'd0 : (blk_rem - 3'd1));
wire bw_full = ~|{video_bw[4] & video_bw[2], video_bw[3] & video_bw[1], video_bw[0]}; // stall when 000/00/0
wire video_start = ~|blk_rem;
wire video_only = stall || (vid_rem == blk_rem);
wire video_idle = ~|vid_rem;

reg [2:0] blk_rem;       // remaining accesses in a block (7..0)
reg stall;
always @(posedge clk) begin
	if (c3) begin
		blk_rem <= blk_nrem;
		if (video_start) stall <= bw_full & go;
	end
end


// track vid_rem counter
// how many video cycles left to the end of block (7..0)
wire [2:0] vid_nrem = (go && video_start) ? vid_nrem_start : (next_vid ? vid_nrem_next : vid_rem);
wire [2:0] vid_nrem_start = (cpu_req && !dev_over_cpu) ? vidmax : (vidmax - 3'd1);
wire [2:0] vid_nrem_next = video_idle ? 3'd0 : (vid_rem - 3'd1);
wire [2:0] vidmax = {video_bw[2:0]};    // number of cycles for video access

reg [2:0] vid_rem;      // remaining video accesses in block
always @(posedge clk) if (c3) vid_rem <= vid_nrem;


// next cycle decision
wire [CYCLES-1:0] cyc_dev = tm_req ? CYC_TM : (ts_req ? CYC_TS : CYC_DMA);
wire dev_req = ts_req || tm_req || dma_req;
// wire dev_over_cpu = (((ts_req || tm_req) && ts_z80_lp) || (dma_req && dma_z80_lp)) && int_n;		// CPU gets higher priority to acknowledge the INT
wire dev_over_cpu = 0;

always @* begin
	if (video_start) begin   // video burst start 
		if (go) begin   // video active line - 38us-ON, 26us-ON
			cpu_next = dev_over_cpu ? 1'b0 : !bw_full;
			next_cycle = dev_over_cpu ? CYC_VID : (bw_full ? CYC_VID : (cpu_req ? CYC_CPU : CYC_VID));
		end
		else begin      // video idle
			cpu_next = !dev_over_cpu;
			next_cycle = dev_over_cpu ? cyc_dev : (cpu_req ? CYC_CPU : (dev_req ? cyc_dev : CYC_FREE));
		end
	end
	else begin         // video burst in progress
		cpu_next = dev_over_cpu ? 1'b0 : !video_only;
		next_cycle = video_only ? CYC_VID : (dev_over_cpu ? cyc_dev : (cpu_req ? CYC_CPU : (!video_idle ? CYC_VID : (dev_req ? cyc_dev : CYC_FREE))));
	end
end

always @(posedge clk) if (c3) curr_cycle <= next_cycle;

// DRAM interface
assign dram_wrdata= curr_dma ? dma_wrdata : {cpu_wrdata,cpu_wrdata};		// write data has to be clocked at c0 in dram.v
assign dram_bsel  = {cpu_wrbsel | next_dma, ~cpu_wrbsel | next_dma};
assign dram_req   = |next_cycle;
assign dram_rnw   = next_cpu ? cpu_rnw : ~next_dma | dma_rnw;
assign dram_addr	= {21{next_cpu}} & cpu_addr
						| {21{next_vid}} & video_addr
						| {21{next_ts }} & ts_addr
						| {21{next_tm }} & tm_addr
						| {21{next_dma}} & dma_addr;

reg cpu_rnw_r;
always @(posedge clk) if (c3) cpu_rnw_r <= cpu_rnw;


// generation of read strobes: for video and cpu
always @(posedge clk) begin
	if (c1) begin
		cpu_strobe <= curr_cpu && cpu_rnw_r;
		cpu_latch <= curr_cpu && cpu_rnw_r;
	end
	else if (c2) cpu_strobe <= 1'b0;
	else if (c3) cpu_latch <= 1'b0; 
end

assign video_pre_next = curr_vid & c1;
assign video_next = curr_vid & c2;
assign video_strobe = curr_vid && c3;
assign video_next_strobe = next_vid && c3;

assign ts_pre_next = curr_ts & c1;
assign ts_next = curr_ts & c2;

assign tm_next = curr_tm & c2;

assign dma_next = curr_dma & c2;


endmodule
