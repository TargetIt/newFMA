// fma_fp32_dot3 — FP32 FMA / Dot-Product, 3-stage pipeline
// Shared multiplier: one 24x24 * for FMA and Dot.
// Dot: 2-phase S1. RN-even, FTZ, INT_W=28.

module fma_fp32_dot3 (
    input  wire        clk, rst_n, valid_i, mode_i,
    input  wire [31:0] a_i, b_i, c_i,
    input  wire [11:0] dx_i, dy_i,
    input  wire [1:0]  dot_p_msb_i,
    output reg         valid_o,
    output reg  [31:0] y_o
);

    localparam INT_W=28, MANT_FULL=24, BIAS=127, AD_PAD=INT_W-1-MANT_FULL;
    reg [23:0] mult_a, mult_b;  reg [47:0] shared_product;
    reg s2_valid; reg [2:0] s2_special; reg [7:0] s2_exp; reg [INT_W-1:0] s2_term1,s2_term2,s2_term3;
    reg [1:0] s2_sign1,s2_sign2,s2_sign3; reg [31:0] s2_special_result;
    reg s3_valid; reg [2:0] s3_special; reg [31:0] s3_special_result; reg [7:0] s3_exp;
    reg s3_result_sign; reg [INT_W-1:0] s3_mant; reg [5:0] s3_lod; reg s3_result_is_zero;
    reg dot_phase; reg [47:0] dot_held_prod; reg [7:0] dot_held_exp; reg dot_held_sign,dot_held_dx_zero;
    reg [23:0] dot_held_ps_mant,dot_held_py_mant; reg [7:0] dot_held_ps_exp,dot_held_py_exp;
    reg dot_held_ps_sign,dot_held_ps_zero,dot_held_py_sign,dot_held_py_zero; reg [11:0] dot_held_dy;

    function [35:0] unpack_ftz; input [31:0] fp; reg [7:0] e; reg [23:0] m;
        begin e=fp[30:23]; m=(e==0||e==8'h00)?24'd0:{1'b1,fp[22:0]};
        unpack_ftz={(e==8'hFF&&fp[22:0]!=0),(e==8'hFF&&fp[22:0]==0),(e==8'h00),fp[31],e,m}; end
    endfunction
    function [35:0] unpack_dot; input [31:0] fp,msb; reg [7:0] e; reg [23:0] m;
        begin e=fp[30:23]; m=(e==0)?24'd0:{msb,fp[22:0]};
        unpack_dot={(e==8'hFF&&fp[22:0]!=0),(e==8'hFF&&fp[22:0]==0),(e==8'h00),fp[31],e,m}; end
    endfunction
    function [INT_W-1:0] log_shr; input [INT_W-1:0] d; input [5:0] s; reg [INT_W-1:0] r;
        begin r=d;if(s[5])r=r>>32;if(s[4])r=r>>16;if(s[3])r=r>>8;if(s[2])r=r>>4;if(s[1])r=r>>2;if(s[0])r=r>>1;log_shr=r; end
    endfunction
    function [INT_W-1:0] log_shl; input [INT_W-1:0] d; input [5:0] s; reg [INT_W-1:0] r;
        begin r=d;if(s[5])r=r<<32;if(s[4])r=r<<16;if(s[3])r=r<<8;if(s[2])r=r<<4;if(s[1])r=r<<2;if(s[0])r=r<<1;log_shl=r; end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            s2_valid<=0;s2_special<=0;s2_exp<=0;s2_term1<=0;s2_term2<=0;s2_term3<=0;
            s2_sign1<=0;s2_sign2<=0;s2_sign3<=0;s2_special_result<=0;
            dot_phase<=0;mult_a<=0;mult_b<=0;
        end else begin
            s2_valid<=valid_i||dot_phase;
            if(valid_i||dot_phase)begin
                reg an,ai,az,as,bn,bi,bz,bs,cn,ci,cz,cs; reg[7:0]ae,be,ce; reg[23:0]am,bm,cm;
                if(dot_phase)begin
                    {cn,ci,cz,cs,ce,cm}=unpack_dot(c_i,dot_p_msb_i[0]);
                end else if(mode_i)begin
                    {an,ai,az,as,ae,am}=unpack_ftz(a_i);
                    {bn,bi,bz,bs,be,bm}=unpack_dot(b_i,dot_p_msb_i[1]);
                    {cn,ci,cz,cs,ce,cm}=unpack_dot(c_i,dot_p_msb_i[0]);
                end else begin
                    {an,ai,az,as,ae,am}=unpack_ftz(a_i);
                    {bn,bi,bz,bs,be,bm}=unpack_ftz(b_i);
                    {cn,ci,cz,cs,ce,cm}=unpack_ftz(c_i);
                end
                if(!dot_phase&&!mode_i)begin mult_a=bm;mult_b=cm;end
                else if(!dot_phase&&mode_i)begin mult_a=bm;mult_b={12'd0,dx_i[10:0]};end
                else begin mult_a=dot_held_py_mant;mult_b={12'd0,dot_held_dy[10:0]};end
                shared_product=mult_a*mult_b;

                if(!mode_i&&!dot_phase)begin // FMA
                    reg[47:0]pm;reg[7:0]pe,anchor;reg[46:0]pma;reg[INT_W-1:0]aa,pa;reg pz;reg[31:0]sr;reg signed[8:0]ad;
                    pm=shared_product;pz=bz||cz;pe=pz?0:(be+ce-BIAS);
                    if(pm[47])begin pma=pm[47:1];pe=pe+1;end else pma=pm[46:0];
                    sr=0;if(an||bn||cn)sr=32'h7FC00000;else if((bi&&cz)||(bz&&ci))sr=32'h7FC00000;
                    else if(ai&&bi&&ci&&(as!=(bs^cs)))sr=32'h7FC00000;
                    else if(ai)sr={as,8'hFF,23'd0};else if(bi||ci)sr={(bi?bs:(ci?cs:1'b0)),8'hFF,23'd0};
                    if(an||bn||cn||ai||bi||ci||(bi&&cz)||(bz&&ci))begin
                        s2_special<=(an||bn||cn)?1:(ai?(as?3:2):(bi?(bs?3:2):(ci?(cs?3:2):0)));
                        s2_special_result<=sr;s2_term1<=0;s2_term2<=0;s2_term3<=0;s2_sign1<=0;s2_sign2<=0;s2_sign3<=0;
                    end else begin
                        if(pe>=ae)begin anchor=pe;pa={1'b0,pma[46:20]};ad=pe-ae;aa=(az||ad>=INT_W)?0:log_shr({1'b0,am,{AD_PAD{1'b0}}},ad[5:0]);end
                        else begin anchor=ae;aa={1'b0,am,{AD_PAD{1'b0}}};ad=ae-pe;pa=(pz||ad>=INT_W)?0:log_shr({1'b0,pma[46:20]},ad[5:0]);end
                        s2_special<=0;s2_special_result<=0;s2_exp<=anchor;s2_term1<=aa;s2_term2<=pa;s2_term3<=0;
                        s2_sign1<=az?0:(as?2:1);s2_sign2<=pz?0:((bs^cs)?2:1);s2_sign3<=0;
                    end
                end else begin // Dot
                    reg[47:0]pd;reg[46:0]pda;reg[7:0]pe2,anchor;reg[5:0]mp;integer j;reg dz;reg[INT_W-1:0]al,dal,dyal;
                    if(!dot_phase)begin // Phase 0
                        if(an||bn||cn||ai||bi||ci||(bi&&(dx_i[10:0]==0)))begin
                            s2_special<=(an||bn||cn)?1:ai?(as?3:2):bi?(bs?3:2):ci?(cs?3:2):1;
                            s2_special_result<=(an||bn||cn)?32'h7FC00000:ai?{as,8'hFF,23'd0}:bi?{bs,8'hFF,23'd0}:ci?{cs,8'hFF,23'd0}:32'h7FC00000;
                            s2_term1<=0;s2_term2<=0;s2_term3<=0;dot_phase<=0;
                        end else begin
                            pd=shared_product;dz=bz||(dx_i[10:0]==0);mp=0;if(!dz)for(j=46;j>=0;j=j-1)if(pd[j]&&mp==0)mp=j[5:0];
                            pda=dz?0:(pd[46:0]<<(46-mp));pe2=dz?0:(be+mp-27);
                            dot_held_prod<={1'b0,pda};dot_held_exp<=pe2;dot_held_sign<=bs;dot_held_dx_zero<=dz;
                            dot_held_ps_mant<=am;dot_held_ps_exp<=ae;dot_held_ps_sign<=as;dot_held_ps_zero<=az;
                            dot_held_py_mant<=cm;dot_held_py_exp<=ce;dot_held_py_sign<=cs;dot_held_py_zero<=cz;
                            dot_held_dy<=dy_i;dot_phase<=1;s2_valid<=0;
                        end
                    end else begin // Phase 1
                        dot_phase<=0;pd=shared_product;dz=dot_held_py_zero||(dot_held_dy[10:0]==0);mp=0;
                        if(!dz)for(j=46;j>=0;j=j-1)if(pd[j]&&mp==0)mp=j[5:0];
                        pda=dz?0:(pd[46:0]<<(46-mp));pe2=dz?0:(dot_held_py_exp+mp-27);
                        anchor=dot_held_ps_exp;if(dot_held_exp>anchor)anchor=dot_held_exp;if(pe2>anchor)anchor=pe2;
                        if(anchor>=dot_held_ps_exp)begin reg[7:0]sh;sh=anchor-dot_held_ps_exp;al=(dot_held_ps_zero||sh>=INT_W)?0:log_shr({1'b0,dot_held_ps_mant,{AD_PAD{1'b0}}},sh[5:0]);end else al=0;
                        if(anchor>=dot_held_exp)begin reg[7:0]sh;sh=anchor-dot_held_exp;dal=(dot_held_dx_zero||sh>=INT_W)?0:log_shr({1'b0,dot_held_prod[46:20]},sh[5:0]);end else dal=0;
                        if(anchor>=pe2)begin reg[7:0]sh;sh=anchor-pe2;dyal=(dz||sh>=INT_W)?0:log_shr({1'b0,pda[46:20]},sh[5:0]);end else dyal={1'b0,pda[46:20]};
                        s2_special<=0;s2_special_result<=0;s2_exp<=anchor;s2_term1<=al;s2_term2<=dal;s2_term3<=dyal;
                        s2_sign1<=dot_held_ps_zero?0:(dot_held_ps_sign?2:1);s2_sign2<=dot_held_dx_zero?0:(dot_held_sign?2:1);s2_sign3<=dz?0:(dot_held_py_sign?2:1);
                    end
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin // Stage 2
        if(!rst_n)begin s3_valid<=0;s3_special<=0;s3_special_result<=0;s3_exp<=0;s3_result_sign<=0;s3_mant<=0;s3_lod<=0;s3_result_is_zero<=0;end
        else begin
            s3_valid<=s2_valid;s3_special<=s2_special;s3_special_result<=s2_special_result;s3_exp<=s2_exp;
            if(s2_valid&&s3_special==0)begin
                reg[INT_W:0]sr;reg rs;reg[INT_W-1:0]sa;reg[5:0]lod;reg signed[INT_W:0]t1,t2,t3;
                t1=(s2_sign1==1)?{1'b0,s2_term1}:(s2_sign1==2)?-{1'b0,s2_term1}:0;
                t2=(s2_sign2==1)?{1'b0,s2_term2}:(s2_sign2==2)?-{1'b0,s2_term2}:0;
                if(|s2_sign3)begin t3=(s2_sign3==1)?{1'b0,s2_term3}:(s2_sign3==2)?-{1'b0,s2_term3}:0;sr=t1+t2+t3;end else sr=t1+t2;
                rs=sr[INT_W];sa=rs?(~sr[INT_W-1:0]+1):sr[INT_W-1:0];lod=0;
                if(sa[27])lod=0;else if(sa[26])lod=1;else if(sa[25])lod=2;else if(sa[24])lod=3;else if(sa[23])lod=4;
                else if(sa[22])lod=5;else if(sa[21])lod=6;else if(sa[20])lod=7;else if(sa[19])lod=8;else if(sa[18])lod=9;
                else if(sa[17])lod=10;else if(sa[16])lod=11;else if(sa[15])lod=12;else if(sa[14])lod=13;else if(sa[13])lod=14;
                else if(sa[12])lod=15;else if(sa[11])lod=16;else if(sa[10])lod=17;else if(sa[9])lod=18;else if(sa[8])lod=19;
                else if(sa[7])lod=20;else if(sa[6])lod=21;else if(sa[5])lod=22;else if(sa[4])lod=23;
                else if(sa[3])lod=24;else if(sa[2])lod=25;else if(sa[1])lod=26;else if(sa[0])lod=27;
                s3_result_sign<=rs;s3_mant<=sa;s3_lod<=lod;s3_result_is_zero<=(sa==0);
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin // Stage 3
        if(!rst_n)begin valid_o<=0;y_o<=0;end else begin
            valid_o<=s3_valid;
            if(s3_valid)begin
                if(s3_special!=0)y_o<=s3_special_result;
                else if(s3_result_is_zero)y_o<=0;
                else begin
                    reg[8:0]ne9;reg[7:0]ne;reg[23:0]nm;reg g,r,s;reg[INT_W-1:0]sm;reg[5:0]sa;
                    sa=s3_lod;sm=log_shl(s3_mant,sa);
                    nm=sm[INT_W-1-:24];ne9={1'b0,s3_exp}+9'd1-{3'b0,sa};ne=ne9[7:0];
                    g=sm[INT_W-25];r=sm[INT_W-26];s=|sm[INT_W-27:0];
                    if(g&&(r||s||nm[0]))begin nm=nm+1;if(nm[23])begin nm=nm>>1;ne9=ne9+1;ne=ne9[7:0];end end
                    if(ne9[8]||ne9==0)y_o<=0;else if(ne9>=9'hFF)y_o<={s3_result_sign,8'hFF,23'd0};else y_o<={s3_result_sign,ne,nm[22:0]};
                end
            end
        end
    end

endmodule
