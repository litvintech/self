pragma circom 2.1.9;

include "../dsc.circom";

component main { public [ merkle_root] } = DSC(36, 64, 4);
