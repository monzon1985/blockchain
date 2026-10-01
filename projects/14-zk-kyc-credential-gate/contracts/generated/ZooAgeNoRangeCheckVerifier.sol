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

contract ZooAgeNoRangeCheckVerifier {
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

    
    uint256 constant IC0x = 3687397965033608578898156222000563879574365650089153054473470838217122894146;
    uint256 constant IC0y = 4040223722359048829823410089257160031536597737361563611431293544820597770178;
    
    uint256 constant IC1x = 18338273485017460164081258355071516247493173429924721684307923342063112227809;
    uint256 constant IC1y = 18946349475583402314967652560168811874033406208620469816932223203302351416122;
    
    uint256 constant IC2x = 4129390010044793646209784775192653068539120276103148280954472837839506589863;
    uint256 constant IC2y = 14808792483665141886069698444625456200070488217825323156020679660597505964181;
    
    uint256 constant IC3x = 10636548146351854663114657815291663811904619693079930961194410041653276817647;
    uint256 constant IC3y = 5385319804294297810047533041415470110816931675924080299176543202985114724681;
    
    uint256 constant IC4x = 1099583618019962863266512923800204797931912230412469750294510815617462826023;
    uint256 constant IC4y = 1810792047233320317571886525330902078669680047715273289893159493610653542399;
    
    uint256 constant IC5x = 14074034548814127643090536523163715379831236294033177907814866439229666437963;
    uint256 constant IC5y = 4348271152949585450126633715668559968432480463901843188677069070254779992997;
    
    uint256 constant IC6x = 12672201714716932878071573388618213699642010504034455731357540435894802905551;
    uint256 constant IC6y = 10438040872011693102479779642936656243465491567658561868995163595394976453048;
    
    uint256 constant IC7x = 7631595023025815102766034059740139568336340752426066261519584452638252992189;
    uint256 constant IC7y = 15357074563916225321234052427316622820408664625809863711597276378492972508864;
    
    uint256 constant IC8x = 18224024188247279230318300387567500356515444438164640509695416995554633718154;
    uint256 constant IC8y = 19327413767481482533550636341960723803939135927405505706447025456584948111054;
    
    uint256 constant IC9x = 15952456552565867482043422975453524048026578444263853554493883535492999167168;
    uint256 constant IC9y = 10348835374602139343417434575480905552701085928421038993957846943047606624562;
    
    uint256 constant IC10x = 17620001074727662231215996531346619260853246294623200091113788027040638047372;
    uint256 constant IC10y = 10742421595953146394964256311883691969183782834906535695058407022051708812920;
    
    uint256 constant IC11x = 18749721265121258080170908509211870419739221662517283450531703303172679024287;
    uint256 constant IC11y = 443380073494435786568656567579668226902219820210398158727604755915672379026;
    
    uint256 constant IC12x = 20558089064049397528044340289914975443224116794004755992834306907222819255481;
    uint256 constant IC12y = 9795367384261569612092815578121517920308658906901653484289967748258723319762;
    
    uint256 constant IC13x = 5262938145554229519724061400930424649439049787461039140845099496433382113071;
    uint256 constant IC13y = 19237612653862645035066132921706813221967073560731112032438545863527990191207;
    
    uint256 constant IC14x = 16338548273636507635400975223706560845672132893542939633065246060549192314137;
    uint256 constant IC14y = 4159149880127628878489354393597455004310571481436474339582397837151287269431;
    
    uint256 constant IC15x = 16653157324276034533034348260895602562518696240294514622057697942499700961601;
    uint256 constant IC15y = 8561505792015596263779242041027735065873293408920885326666883389831512467222;
    
    uint256 constant IC16x = 371490773195748381276055842725400776669896757479984694415199819002700033789;
    uint256 constant IC16y = 5117429880643887441159350084957228486359387037458184179695321344427902798295;
    
    uint256 constant IC17x = 3035446986478924402713075545549063577630478371550010149183541457013930878987;
    uint256 constant IC17y = 14246527441471542753382081832063174829756046373715131858805322436651113135766;
    
    uint256 constant IC18x = 15471510009437294784331164805507711744303692431976639174824542452890305088645;
    uint256 constant IC18y = 1202950697910779550640457203361883944864474628802589745382523517711805600066;
    
    uint256 constant IC19x = 5322134197583828511973983356735226551781122026114142510253621494748523773298;
    uint256 constant IC19y = 10829837894272510979905161468703600655273516048376638682322697947905252901816;
    
    uint256 constant IC20x = 18852700194114397418511425854047662328881105546413603339665667544621313803580;
    uint256 constant IC20y = 38025112179444379547931627575749584415190855852359508960316279722434618492;
    
    uint256 constant IC21x = 15901347560439914287902976659900875830915638171329409600881400880262232513465;
    uint256 constant IC21y = 85968605710985600836289812356369464170838029580305877638475519965964857;
    
    uint256 constant IC22x = 16513268525487337917137873981517987363731913301387132142843092693297443703262;
    uint256 constant IC22y = 19424780456851476351668664173147046303665838683965743956216628862964576004830;
    
 
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
