// SPDX-License-Identifier: GPL-3.0
/*
    Copyright 2021 0KIMS association.

    This file is generated with [snarkJS](https://github.com/iden3/snarkjs).

    snarkJS is a free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    snarkJS is distributed in the hope that it will be useful, but WITHOUT
    ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
    or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public
    License for more details.

    You should have received a copy of the GNU General Public License
    along with snarkJS. If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity >=0.7.0 <0.9.0;

contract ZooMerkleSelectorVerifier {
    // Scalar field size
    uint256 constant r    = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    // Base field size
    uint256 constant q   = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // Verification Key data
    uint256 constant alphax  = 5858668097392295807115862064928183243152926195004806556409207892169848243973;
    uint256 constant alphay  = 16889472165325966692513388623304128100494788222995509180774344459936541183923;
    uint256 constant betax1  = 13054541654379547423740480719588767373324024137343072584910455665263358338436;
    uint256 constant betax2  = 14109877599173059371595263004073791453419738212490338703652160712174242474175;
    uint256 constant betay1  = 6456534181524234637681887093326917896007850901655868552211740974657412313630;
    uint256 constant betay2  = 20552567824852853696771619095907610160495335424171854967141203255845724092462;
    uint256 constant gammax1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 constant gammax2 = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 constant gammay1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 constant gammay2 = 8495653923123431417604973247489272438418190587263600148770280649306958101930;
    uint256 constant deltax1 = 9713205903959976771216577871559386924489093847677542498728240772288588234435;
    uint256 constant deltax2 = 18384999736104945557792365601267669401303844352050011261904674175034489529756;
    uint256 constant deltay1 = 18326323810722852420640773998965462965327111841197721293118185423203699200990;
    uint256 constant deltay2 = 6384802026224171062873555044906402993554741939341387072866052692708348128041;

    
    uint256 constant IC0x = 10943097227141646455753305290464634237526263605949355392285948423756183226725;
    uint256 constant IC0y = 3116394495722751653330473909070514070051945309890914371800457775407836466079;
    
    uint256 constant IC1x = 10669902952830508205159157404378762680096770249940213682817090766294519063868;
    uint256 constant IC1y = 156681005870603041877618060133127860018883876231127214845246616946176151647;
    
    uint256 constant IC2x = 17543184029364489988179534784188140816308398323484374013445139831922450663764;
    uint256 constant IC2y = 4852410295502541114320876209848235604766808190105628334822503188850265424111;
    
    uint256 constant IC3x = 19772293509184294430449741686195194937100415472574647664497056285482486090854;
    uint256 constant IC3y = 7397229527572106932486626879974439712762561579326834284897591559982737531547;
    
    uint256 constant IC4x = 12887826355916719814492875277343638649549563274236134330168223049860575839893;
    uint256 constant IC4y = 12560445641668217929279093202399182127472172747575410365845288975567287200564;
    
    uint256 constant IC5x = 13113912649919384039650576704173407851322657821848650575896824580113149596247;
    uint256 constant IC5y = 18922305706637549063895105070815140322697189400583264464938330560504433423876;
    
    uint256 constant IC6x = 8615999384940659957178530761976927890756006236233149054016442227611181961161;
    uint256 constant IC6y = 11300522737536548203701953992104992093693935576241135804980494353513112073605;
    
    uint256 constant IC7x = 19525737844994463254574953300769872677284107058772086374036865228274146038621;
    uint256 constant IC7y = 17530670846047175313925343822731161245493972956480809634220549757428270144102;
    
    uint256 constant IC8x = 11198587127202686235802187444543562682131353392703725846156549935574332128676;
    uint256 constant IC8y = 5163023033968271958242157993490140822845013957655289174802944897653213053932;
    
    uint256 constant IC9x = 11012128979018985518149441001572619013182400037351561546162230378588137907400;
    uint256 constant IC9y = 8874923733449124496152288283904718383583713252502946706891047127372108169276;
    
    uint256 constant IC10x = 11711994242877155272564536310650824767741348581946581529390490068337870972710;
    uint256 constant IC10y = 17564942851137289883212984427139955366407732959139185145608469157765005293693;
    
    uint256 constant IC11x = 2939365743281824191193125523074627223515636785975856104582164069583354628191;
    uint256 constant IC11y = 16122893956734958472220955595647001686048153379317970275531010249310703649401;
    
    uint256 constant IC12x = 20319996247233731948236272170488457496687204754551858435632814775528618834629;
    uint256 constant IC12y = 4886493403793785084445519237896237777432993865089050107356485760142686065636;
    
    uint256 constant IC13x = 16849094785641415769234233405802587049863326490620939355535200647624022808318;
    uint256 constant IC13y = 17247901077848181654099734690998063286054730617816273836275508083489994804029;
    
    uint256 constant IC14x = 10912780906421237918184617931737707649924445388009067415475570634363536843743;
    uint256 constant IC14y = 2493285294806136884882919839204675600366949366305790113367687148375409670265;
    
    uint256 constant IC15x = 3997349983673300269540385938216763387521578755015027637326845934238365330008;
    uint256 constant IC15y = 11692885667130599414705358779407270431033342353265345204005468062208653392174;
    
    uint256 constant IC16x = 3784495151406614337596867720993657123360159914350231790390113548009894159096;
    uint256 constant IC16y = 15267418412643339653673763356348812124407887212913281991377070735234713469461;
    
    uint256 constant IC17x = 16610949591197162548192195661348603848759801439493528052930238662245224534765;
    uint256 constant IC17y = 16224403227885559652089672341049746977159974591975051434744745406608219274960;
    
    uint256 constant IC18x = 17750583182190937891706683638790904026248475727503779223641880979276567111866;
    uint256 constant IC18y = 8116394148134097346146234832659938746985669935343594438836224883983966787850;
    
    uint256 constant IC19x = 3149589143510657937252378747316979670768019487368812083124120406490890245424;
    uint256 constant IC19y = 12165652422644683425527105514910855460760097784142904181592731692813793597118;
    
    uint256 constant IC20x = 3173675992293290029265641870003280468149840615280005013656997019899097494425;
    uint256 constant IC20y = 20058030500278210571623494615019409587048202597611443848645267902750505230397;
    
    uint256 constant IC21x = 10154652584150165709402452911456569059791223285935903981984848676118582717807;
    uint256 constant IC21y = 5501040659735843842347157573385559968166333013420730031699447609566453771821;
    
    uint256 constant IC22x = 10747975306320917266804035286608734145609148447990722379415969563666157039328;
    uint256 constant IC22y = 11211338671582206724151342033289951508776666805432787038906981660039424551074;
    
 
    // Memory data
    uint16 constant pVk = 0;
    uint16 constant pPairing = 128;

    uint16 constant pLastMem = 896;

    function verifyProof(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[22] calldata _pubSignals) public view returns (bool) {
        assembly {
            function checkField(v) {
                if iszero(lt(v, r)) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }
            
            // G1 function to multiply a G1 value(x,y) to value in an address
            function g1_mulAccC(pR, x, y, s) {
                let success
                let mIn := mload(0x40)
                mstore(mIn, x)
                mstore(add(mIn, 32), y)
                mstore(add(mIn, 64), s)

                success := staticcall(sub(gas(), 2000), 7, mIn, 96, mIn, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }

                mstore(add(mIn, 64), mload(pR))
                mstore(add(mIn, 96), mload(add(pR, 32)))

                success := staticcall(sub(gas(), 2000), 6, mIn, 128, pR, 64)

                if iszero(success) {
                    mstore(0, 0)
                    return(0, 0x20)
                }
            }

            function checkPairing(pA, pB, pC, pubSignals, pMem) -> isOk {
                let _pPairing := add(pMem, pPairing)
                let _pVk := add(pMem, pVk)

                mstore(_pVk, IC0x)
                mstore(add(_pVk, 32), IC0y)

                // Compute the linear combination vk_x
                
                g1_mulAccC(_pVk, IC1x, IC1y, calldataload(add(pubSignals, 0)))
                
                g1_mulAccC(_pVk, IC2x, IC2y, calldataload(add(pubSignals, 32)))
                
                g1_mulAccC(_pVk, IC3x, IC3y, calldataload(add(pubSignals, 64)))
                
                g1_mulAccC(_pVk, IC4x, IC4y, calldataload(add(pubSignals, 96)))
                
                g1_mulAccC(_pVk, IC5x, IC5y, calldataload(add(pubSignals, 128)))
                
                g1_mulAccC(_pVk, IC6x, IC6y, calldataload(add(pubSignals, 160)))
                
                g1_mulAccC(_pVk, IC7x, IC7y, calldataload(add(pubSignals, 192)))
                
                g1_mulAccC(_pVk, IC8x, IC8y, calldataload(add(pubSignals, 224)))
                
                g1_mulAccC(_pVk, IC9x, IC9y, calldataload(add(pubSignals, 256)))
                
                g1_mulAccC(_pVk, IC10x, IC10y, calldataload(add(pubSignals, 288)))
                
                g1_mulAccC(_pVk, IC11x, IC11y, calldataload(add(pubSignals, 320)))
                
                g1_mulAccC(_pVk, IC12x, IC12y, calldataload(add(pubSignals, 352)))
                
                g1_mulAccC(_pVk, IC13x, IC13y, calldataload(add(pubSignals, 384)))
                
                g1_mulAccC(_pVk, IC14x, IC14y, calldataload(add(pubSignals, 416)))
                
                g1_mulAccC(_pVk, IC15x, IC15y, calldataload(add(pubSignals, 448)))
                
                g1_mulAccC(_pVk, IC16x, IC16y, calldataload(add(pubSignals, 480)))
                
                g1_mulAccC(_pVk, IC17x, IC17y, calldataload(add(pubSignals, 512)))
                
                g1_mulAccC(_pVk, IC18x, IC18y, calldataload(add(pubSignals, 544)))
                
                g1_mulAccC(_pVk, IC19x, IC19y, calldataload(add(pubSignals, 576)))
                
                g1_mulAccC(_pVk, IC20x, IC20y, calldataload(add(pubSignals, 608)))
                
                g1_mulAccC(_pVk, IC21x, IC21y, calldataload(add(pubSignals, 640)))
                
                g1_mulAccC(_pVk, IC22x, IC22y, calldataload(add(pubSignals, 672)))
                

                // -A
                mstore(_pPairing, calldataload(pA))
                mstore(add(_pPairing, 32), mod(sub(q, calldataload(add(pA, 32))), q))

                // B
                mstore(add(_pPairing, 64), calldataload(pB))
                mstore(add(_pPairing, 96), calldataload(add(pB, 32)))
                mstore(add(_pPairing, 128), calldataload(add(pB, 64)))
                mstore(add(_pPairing, 160), calldataload(add(pB, 96)))

                // alpha1
                mstore(add(_pPairing, 192), alphax)
                mstore(add(_pPairing, 224), alphay)

                // beta2
                mstore(add(_pPairing, 256), betax1)
                mstore(add(_pPairing, 288), betax2)
                mstore(add(_pPairing, 320), betay1)
                mstore(add(_pPairing, 352), betay2)

                // vk_x
                mstore(add(_pPairing, 384), mload(add(pMem, pVk)))
                mstore(add(_pPairing, 416), mload(add(pMem, add(pVk, 32))))


                // gamma2
                mstore(add(_pPairing, 448), gammax1)
                mstore(add(_pPairing, 480), gammax2)
                mstore(add(_pPairing, 512), gammay1)
                mstore(add(_pPairing, 544), gammay2)

                // C
                mstore(add(_pPairing, 576), calldataload(pC))
                mstore(add(_pPairing, 608), calldataload(add(pC, 32)))

                // delta2
                mstore(add(_pPairing, 640), deltax1)
                mstore(add(_pPairing, 672), deltax2)
                mstore(add(_pPairing, 704), deltay1)
                mstore(add(_pPairing, 736), deltay2)


                let success := staticcall(sub(gas(), 2000), 8, _pPairing, 768, _pPairing, 0x20)

                isOk := and(success, mload(_pPairing))
            }

            let pMem := mload(0x40)
            mstore(0x40, add(pMem, pLastMem))

            // Validate that all evaluations ∈ F
            
            checkField(calldataload(add(_pubSignals, 0)))
            
            checkField(calldataload(add(_pubSignals, 32)))
            
            checkField(calldataload(add(_pubSignals, 64)))
            
            checkField(calldataload(add(_pubSignals, 96)))
            
            checkField(calldataload(add(_pubSignals, 128)))
            
            checkField(calldataload(add(_pubSignals, 160)))
            
            checkField(calldataload(add(_pubSignals, 192)))
            
            checkField(calldataload(add(_pubSignals, 224)))
            
            checkField(calldataload(add(_pubSignals, 256)))
            
            checkField(calldataload(add(_pubSignals, 288)))
            
            checkField(calldataload(add(_pubSignals, 320)))
            
            checkField(calldataload(add(_pubSignals, 352)))
            
            checkField(calldataload(add(_pubSignals, 384)))
            
            checkField(calldataload(add(_pubSignals, 416)))
            
            checkField(calldataload(add(_pubSignals, 448)))
            
            checkField(calldataload(add(_pubSignals, 480)))
            
            checkField(calldataload(add(_pubSignals, 512)))
            
            checkField(calldataload(add(_pubSignals, 544)))
            
            checkField(calldataload(add(_pubSignals, 576)))
            
            checkField(calldataload(add(_pubSignals, 608)))
            
            checkField(calldataload(add(_pubSignals, 640)))
            
            checkField(calldataload(add(_pubSignals, 672)))
            

            // Validate all evaluations
            let isValid := checkPairing(_pA, _pB, _pC, _pubSignals, pMem)

            mstore(0, isValid)
             return(0, 0x20)
         }
     }
 }
