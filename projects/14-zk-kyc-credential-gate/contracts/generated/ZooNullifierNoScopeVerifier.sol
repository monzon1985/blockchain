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

contract ZooNullifierNoScopeVerifier {
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

    
    uint256 constant IC0x = 7753544094761033536858631802881534375036766146384651219312478706568000121999;
    uint256 constant IC0y = 12033877220411449410690223353209565558266824356569511410870765526622544563314;
    
    uint256 constant IC1x = 5574475844935871997339063937167354498741106362406102852281324966052707050296;
    uint256 constant IC1y = 11455135317012736279774501949378969573903677369590044847506003630614246820495;
    
    uint256 constant IC2x = 4753127734532653039019023455527187551926582420286342742864881312021457348162;
    uint256 constant IC2y = 4103860807754739829518146199682715878268569916592579951432069795143551439941;
    
    uint256 constant IC3x = 19256582289608754227604843370602176579509559910704746366393225869574020909689;
    uint256 constant IC3y = 4400997514581831840113171572585382302528941564811080096676188275621743741609;
    
    uint256 constant IC4x = 8246876292231615779400494587013523813811961333865686914191966457916906477496;
    uint256 constant IC4y = 1753680290201708077863116924244827608721958843230767852602290241046714281170;
    
    uint256 constant IC5x = 15253731751573008086565682390239907985443576751511221006810671504356045193213;
    uint256 constant IC5y = 13830113193398375513967281071861185856799371940196118161754967420429563238351;
    
    uint256 constant IC6x = 18985918482711539988014749682831472806863160370325359559578449103469542715763;
    uint256 constant IC6y = 17254066364714640442140570243559655332011218233675368371536511636357390719262;
    
    uint256 constant IC7x = 14542682212407144481059299249130656654165254222649279905477871400750597784220;
    uint256 constant IC7y = 21544208255445401543459974955957845444426484824501574569957818956317744923314;
    
    uint256 constant IC8x = 21099970513664178466220422280418236874876646119055808581502027790355626601920;
    uint256 constant IC8y = 9592860422136114335269376219018034133538626365552065752721763977041270756691;
    
    uint256 constant IC9x = 16572092880243563724376049957557852895208417544102669532088100467447716077950;
    uint256 constant IC9y = 19660991777597693281155313557750109049365143710618953062789403374468358905230;
    
    uint256 constant IC10x = 4924248497185296553767254823609068859080451152888020836182914397774734346904;
    uint256 constant IC10y = 19165647189459237729393932807924679240737626234522719731380760714637301244812;
    
    uint256 constant IC11x = 10940214217438294304568997852466447661455655460638343644844987609469931344417;
    uint256 constant IC11y = 7295422886696624580588655198981120987369906491725780587331763358835181283478;
    
    uint256 constant IC12x = 19630566343120488563067180134760225317251292852260550718952940039995349001390;
    uint256 constant IC12y = 1106455357436546410220690603602759032010158817856333787884130683059026973124;
    
    uint256 constant IC13x = 8243802387319526363035657481528574452489024216728032500963761558297506373562;
    uint256 constant IC13y = 4584534729116525568375527677062884765956014321248711061081302046149053144343;
    
    uint256 constant IC14x = 11769205606732816824159188944007485294964390423238069846262676197947899429038;
    uint256 constant IC14y = 13196197179193671335109436410843494843666149325673132982675893887331525394978;
    
    uint256 constant IC15x = 20425555832018424603570271743896151136721447057293976045932812000603082938136;
    uint256 constant IC15y = 17221830732671364963871822950506313074818382111226818925428063679051856872953;
    
    uint256 constant IC16x = 14903208273198862391135964003487541381130545195828852182167859027395814629398;
    uint256 constant IC16y = 7443663528247075519218572768178814412097972071154152688330576893429750009981;
    
    uint256 constant IC17x = 14176155211577145319964212281628331613763486894265236403523793164396879800818;
    uint256 constant IC17y = 13045901711136565101426143809542468086215303099402657062663083412862729027246;
    
    uint256 constant IC18x = 2278713015604010443151718803089183042314879801739655592993410821640973218720;
    uint256 constant IC18y = 4118869159399972804019893014940140031003585667283396410999930477038091380053;
    
    uint256 constant IC19x = 21146804412178318661704968006651485237354515601971230620034384969576993182570;
    uint256 constant IC19y = 12002810760741207926324368155434393329002860610551596652839443940608256319041;
    
    uint256 constant IC20x = 20675574743588447212572558099643029024707715927445469976561703896679231126666;
    uint256 constant IC20y = 9342613862025190974410437337586196381432560230457610550614303299878621204462;
    
    uint256 constant IC21x = 7344247972012249877984283655677483773552448130809937411575364587963395697191;
    uint256 constant IC21y = 3886818781515015996505571254896713464794414296393943670853272783743671464779;
    
    uint256 constant IC22x = 6222393111898749136317821647243594395285454001167562429983767777137116234612;
    uint256 constant IC22y = 13415187566147336401532166500790051137285292591837720599199741041144259104032;
    
 
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
