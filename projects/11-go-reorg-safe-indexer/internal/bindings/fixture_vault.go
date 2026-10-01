// Code generated via abigen V2 - DO NOT EDIT.
// This file is a generated binding and any manual changes will be lost.
// SPDX-License-Identifier: MIT

package bindings

import (
	"bytes"
	"errors"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind/v2"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

// Reference imports to suppress errors if they are not otherwise used.
var (
	_ = bytes.Equal
	_ = errors.New
	_ = big.NewInt
	_ = common.Big1
	_ = types.BloomLookup
	_ = abi.ConvertType
)

// FixtureVaultMetaData contains all meta data concerning the FixtureVault contract.
var FixtureVaultMetaData = bind.MetaData{
	ABI: "[{\"type\":\"constructor\",\"inputs\":[{\"name\":\"asset_\",\"type\":\"address\",\"internalType\":\"contractIERC20\"},{\"name\":\"name_\",\"type\":\"string\",\"internalType\":\"string\"},{\"name\":\"symbol_\",\"type\":\"string\",\"internalType\":\"string\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"allowance\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"approve\",\"inputs\":[{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"asset\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"balanceOf\",\"inputs\":[{\"name\":\"account\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"convertToAssets\",\"inputs\":[{\"name\":\"shares\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"convertToShares\",\"inputs\":[{\"name\":\"assets\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"decimals\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"uint8\",\"internalType\":\"uint8\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"deposit\",\"inputs\":[{\"name\":\"assets\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"receiver\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"maxDeposit\",\"inputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"maxMint\",\"inputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"maxRedeem\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"maxWithdraw\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"mint\",\"inputs\":[{\"name\":\"shares\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"receiver\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"name\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"string\",\"internalType\":\"string\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"previewDeposit\",\"inputs\":[{\"name\":\"assets\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"previewMint\",\"inputs\":[{\"name\":\"shares\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"previewRedeem\",\"inputs\":[{\"name\":\"shares\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"previewWithdraw\",\"inputs\":[{\"name\":\"assets\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"redeem\",\"inputs\":[{\"name\":\"shares\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"receiver\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"symbol\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"string\",\"internalType\":\"string\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"totalAssets\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"totalSupply\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"transfer\",\"inputs\":[{\"name\":\"to\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"transferFrom\",\"inputs\":[{\"name\":\"from\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"to\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"withdraw\",\"inputs\":[{\"name\":\"assets\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"receiver\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"event\",\"name\":\"Approval\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"spender\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"Deposit\",\"inputs\":[{\"name\":\"sender\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"owner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"assets\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"},{\"name\":\"shares\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"Transfer\",\"inputs\":[{\"name\":\"from\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"to\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"Withdraw\",\"inputs\":[{\"name\":\"sender\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"receiver\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"owner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"assets\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"},{\"name\":\"shares\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"error\",\"name\":\"ERC20InsufficientAllowance\",\"inputs\":[{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"allowance\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"needed\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"ERC20InsufficientBalance\",\"inputs\":[{\"name\":\"sender\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"balance\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"needed\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidApprover\",\"inputs\":[{\"name\":\"approver\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidReceiver\",\"inputs\":[{\"name\":\"receiver\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidSender\",\"inputs\":[{\"name\":\"sender\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidSpender\",\"inputs\":[{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC4626ExceededMaxDeposit\",\"inputs\":[{\"name\":\"receiver\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"assets\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"max\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"ERC4626ExceededMaxMint\",\"inputs\":[{\"name\":\"receiver\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"shares\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"max\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"ERC4626ExceededMaxRedeem\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"shares\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"max\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"ERC4626ExceededMaxWithdraw\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"assets\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"max\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"SafeERC20FailedOperation\",\"inputs\":[{\"name\":\"token\",\"type\":\"address\",\"internalType\":\"address\"}]}]",
	ID:  "FixtureVault",
	Bin: "0x60c060405234801561000f575f5ffd5b506040516118f53803806118f583398101604081905261002e9161015d565b828282600361003d838261026e565b50600461004a828261026e565b5050505f5f61005e8361008d60201b60201c565b915091508161006e576012610070565b805b60ff1660a05250506001600160a01b03166080525061032c915050565b63313ce56760e01b5f818152908190602082600481875afa5f51601f3d1190911661010082101695908602945092505050565b634e487b7160e01b5f52604160045260245ffd5b5f82601f8301126100e3575f5ffd5b81516001600160401b038111156100fc576100fc6100c0565b604051601f8201601f19908116603f011681016001600160401b038111828210171561012a5761012a6100c0565b604052818152838201602001851015610141575f5ffd5b8160208501602083015e5f918101602001919091529392505050565b5f5f5f6060848603121561016f575f5ffd5b83516001600160a01b0381168114610185575f5ffd5b60208501519093506001600160401b038111156101a0575f5ffd5b6101ac868287016100d4565b604086015190935090506001600160401b038111156101c9575f5ffd5b6101d5868287016100d4565b9150509250925092565b600181811c908216806101f357607f821691505b60208210810361021157634e487b7160e01b5f52602260045260245ffd5b50919050565b601f821115610269578282111561026957805f5260205f20601f840160051c602085101561024257505f5b90810190601f840160051c035f5b81811015610265575f83820155600101610250565b5050505b505050565b81516001600160401b03811115610287576102876100c0565b61029b8161029584546101df565b84610217565b6020601f8211600181146102cd575f83156102b65750848201515b5f19600385901b1c1916600184901b178455610325565b5f84815260208120601f198516915b828110156102fc57878501518255602094850194600190920191016102dc565b508482101561031957868401515f19600387901b60f8161c191681555b505060018360011b0184555b5050505050565b60805160a0516115936103625f395f61057701525f8181610266015281816103d401528181610dc40152610ea801526115935ff3fe608060405234801561000f575f5ffd5b506004361061019a575f3560e01c806370a08231116100e8578063ba08765211610093578063ce96cb771161006e578063ce96cb7714610366578063d905777e14610379578063dd62ed3e1461038c578063ef8b30f714610353575f5ffd5b8063ba08765214610340578063c63d75b614610290578063c6e6f59214610353575f5ffd5b8063a9059cbb116100c3578063a9059cbb14610307578063b3d7f6b91461031a578063b460af941461032d575f5ffd5b806370a08231146102b757806394bf804d146102ec57806395d89b41146102ff575f5ffd5b806323b872dd11610148578063402d267d11610123578063402d267d146102905780634cdad506146101ce5780636e553f65146102a4575f5ffd5b806323b872dd1461021f578063313ce5671461023257806338d52e0f1461024c575f5ffd5b8063095ea7b311610178578063095ea7b3146101e15780630a28a4771461020457806318160ddd14610217575f5ffd5b806301e1d1141461019e57806306fdde03146101b957806307a2d13a146101ce575b5f5ffd5b6101a66103d1565b6040519081526020015b60405180910390f35b6101c1610486565b6040516101b091906111a9565b6101a66101dc3660046111fc565b610516565b6101f46101ef36600461123b565b610527565b60405190151581526020016101b0565b6101a66102123660046111fc565b61053e565b6002546101a6565b6101f461022d366004611263565b61054a565b61023a61056f565b60405160ff90911681526020016101b0565b60405173ffffffffffffffffffffffffffffffffffffffff7f00000000000000000000000000000000000000000000000000000000000000001681526020016101b0565b6101a661029e36600461129d565b505f1990565b6101a66102b23660046112b6565b61059b565b6101a66102c536600461129d565b73ffffffffffffffffffffffffffffffffffffffff165f9081526020819052604090205490565b6101a66102fa3660046112b6565b6105cc565b6101c16105e7565b6101f461031536600461123b565b6105f6565b6101a66103283660046111fc565b610603565b6101a661033b3660046112e0565b61060f565b6101a661034e3660046112e0565b61069e565b6101a66103613660046111fc565b610724565b6101a661037436600461129d565b61072f565b6101a661038736600461129d565b610738565b6101a661039a366004611319565b73ffffffffffffffffffffffffffffffffffffffff9182165f90815260016020908152604080832093909416825291909152205490565b5f7f00000000000000000000000000000000000000000000000000000000000000006040517f70a0823100000000000000000000000000000000000000000000000000000000815230600482015273ffffffffffffffffffffffffffffffffffffffff91909116906370a0823190602401602060405180830381865afa15801561045d573d5f5f3e3d5ffd5b505050506040513d601f19601f820116820180604052508101906104819190611341565b905090565b60606003805461049590611358565b80601f01602080910402602001604051908101604052809291908181526020018280546104c190611358565b801561050c5780601f106104e35761010080835404028352916020019161050c565b820191905f5260205f20905b8154815290600101906020018083116104ef57829003601f168201915b5050505050905090565b5f610521825f610762565b92915050565b5f3361053481858561079b565b5060019392505050565b5f6105218260016107ad565b5f336105578582856107dd565b61056285858561088c565b60019150505b9392505050565b5f61048160037f00000000000000000000000000000000000000000000000000000000000000006113d6565b5f5f196105ac565b60405180910390fd5b5f6105b685610724565b90506105c433858784610935565b949350505050565b5f5f195f6105d985610603565b90506105c433858388610935565b60606004805461049590611358565b5f3361053481858561088c565b5f610521826001610762565b5f5f61061a8361072f565b90508085111561067c576040517ffe9cceec00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff8416600482015260248101869052604481018290526064016105a3565b5f6106868661053e565b905061069533868689856109bf565b95945050505050565b5f5f6106a983610738565b90508085111561070b576040517fb94abeec00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff8416600482015260248101869052604481018290526064016105a3565b5f61071586610516565b9050610695338686848a6109bf565b5f610521825f6107ad565b5f6105216101dc835b73ffffffffffffffffffffffffffffffffffffffff81165f90815260208190526040812054610521565b5f61056861076e6103d1565b6107799060016113ef565b6107856003600a6114e5565b60025461079291906113ef565b85919085610a9f565b6107a88383836001610ae1565b505050565b5f6105686107bd6003600a6114e5565b6002546107ca91906113ef565b6107d26103d1565b6107929060016113ef565b73ffffffffffffffffffffffffffffffffffffffff8381165f908152600160209081526040808320938616835292905220545f198110156108865781811015610878576040517ffb8f41b200000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff8416600482015260248101829052604481018390526064016105a3565b61088684848484035f610ae1565b50505050565b73ffffffffffffffffffffffffffffffffffffffff83166108db576040517f96c6fd1e0000000000000000000000000000000000000000000000000000000081525f60048201526024016105a3565b73ffffffffffffffffffffffffffffffffffffffff821661092a576040517fec442f050000000000000000000000000000000000000000000000000000000081525f60048201526024016105a3565b6107a8838383610c18565b61093f8483610dbf565b6109498382610def565b8273ffffffffffffffffffffffffffffffffffffffff168473ffffffffffffffffffffffffffffffffffffffff167fdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d784846040516109b1929190918252602082015260400190565b60405180910390a350505050565b8273ffffffffffffffffffffffffffffffffffffffff168573ffffffffffffffffffffffffffffffffffffffff16146109fd576109fd8386836107dd565b610a078382610e49565b610a118483610ea3565b8273ffffffffffffffffffffffffffffffffffffffff168473ffffffffffffffffffffffffffffffffffffffff168673ffffffffffffffffffffffffffffffffffffffff167ffbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db8585604051610a90929190918252602082015260400190565b60405180910390a45050505050565b5f610acc610aac83610ece565b8015610ac757505f8480610ac257610ac26114f3565b868809115b151590565b610ad7868686610efa565b61069591906113ef565b73ffffffffffffffffffffffffffffffffffffffff8416610b30576040517fe602df050000000000000000000000000000000000000000000000000000000081525f60048201526024016105a3565b73ffffffffffffffffffffffffffffffffffffffff8316610b7f576040517f94280d620000000000000000000000000000000000000000000000000000000081525f60048201526024016105a3565b73ffffffffffffffffffffffffffffffffffffffff8085165f9081526001602090815260408083209387168352929052208290558015610886578273ffffffffffffffffffffffffffffffffffffffff168473ffffffffffffffffffffffffffffffffffffffff167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925846040516109b191815260200190565b73ffffffffffffffffffffffffffffffffffffffff8316610c4f578060025f828254610c4491906113ef565b90915550610cff9050565b73ffffffffffffffffffffffffffffffffffffffff83165f9081526020819052604090205481811015610cd4576040517fe450d38c00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff8516600482015260248101829052604481018390526064016105a3565b73ffffffffffffffffffffffffffffffffffffffff84165f9081526020819052604090209082900390555b73ffffffffffffffffffffffffffffffffffffffff8216610d2857600280548290039055610d53565b73ffffffffffffffffffffffffffffffffffffffff82165f9081526020819052604090208054820190555b8173ffffffffffffffffffffffffffffffffffffffff168373ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef83604051610db291815260200190565b60405180910390a3505050565b610deb7f0000000000000000000000000000000000000000000000000000000000000000833084610faa565b5050565b73ffffffffffffffffffffffffffffffffffffffff8216610e3e576040517fec442f050000000000000000000000000000000000000000000000000000000081525f60048201526024016105a3565b610deb5f8383610c18565b73ffffffffffffffffffffffffffffffffffffffff8216610e98576040517f96c6fd1e0000000000000000000000000000000000000000000000000000000081525f60048201526024016105a3565b610deb825f83610c18565b610deb7f00000000000000000000000000000000000000000000000000000000000000008383611006565b5f6002826003811115610ee357610ee3611520565b610eed919061154d565b60ff166001149050919050565b5f5f5f610f078686611061565b91509150815f03610f2b57838181610f2157610f216114f3565b0492505050610568565b818411610f4257610f42600385150260111861107d565b5f848688095f868103871696879004966002600389028118808a02820302808a02820302808a02820302808a02820302808a02820302808a02909103029181900381900460010185841190960395909502919093039390930492909217029150509392505050565b610fb884848484600161108e565b610886576040517f5274afe700000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff851660048201526024016105a3565b6110138383836001611121565b6107a8576040517f5274afe700000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff841660048201526024016105a3565b5f805f1983850993909202808410938190039390930393915050565b634e487b715f52806020526024601cfd5b6040517f23b872dd000000000000000000000000000000000000000000000000000000005f81815273ffffffffffffffffffffffffffffffffffffffff8781166004528616602452604485905291602083606481808c5af1925060015f51148316611110578383151615611104573d5f823e3d81fd5b5f883b113d1516831692505b604052505f60605295945050505050565b6040517fa9059cbb000000000000000000000000000000000000000000000000000000005f81815273ffffffffffffffffffffffffffffffffffffffff8616600452602485905291602083604481808b5af1925060015f5114831661119d578383151615611191573d5f823e3d81fd5b5f873b113d1516831692505b60405250949350505050565b602081525f82518060208401528060208501604085015e5f6040828501015260407fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f83011684010191505092915050565b5f6020828403121561120c575f5ffd5b5035919050565b803573ffffffffffffffffffffffffffffffffffffffff81168114611236575f5ffd5b919050565b5f5f6040838503121561124c575f5ffd5b61125583611213565b946020939093013593505050565b5f5f5f60608486031215611275575f5ffd5b61127e84611213565b925061128c60208501611213565b929592945050506040919091013590565b5f602082840312156112ad575f5ffd5b61056882611213565b5f5f604083850312156112c7575f5ffd5b823591506112d760208401611213565b90509250929050565b5f5f5f606084860312156112f2575f5ffd5b8335925061130260208501611213565b915061131060408501611213565b90509250925092565b5f5f6040838503121561132a575f5ffd5b61133383611213565b91506112d760208401611213565b5f60208284031215611351575f5ffd5b5051919050565b600181811c9082168061136c57607f821691505b6020821081036113a3577f4e487b71000000000000000000000000000000000000000000000000000000005f52602260045260245ffd5b50919050565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b60ff8181168382160190811115610521576105216113a9565b80820180821115610521576105216113a9565b6001815b600184111561143d57808504811115611421576114216113a9565b600184161561142f57908102905b60019390931c928002611406565b935093915050565b5f8261145357506001610521565b8161145f57505f610521565b8160018114611475576002811461147f5761149b565b6001915050610521565b60ff841115611490576114906113a9565b50506001821b610521565b5060208310610133831016604e8410600b84101617156114be575081810a610521565b6114ca5f198484611402565b805f19048211156114dd576114dd6113a9565b029392505050565b5f61056860ff841683611445565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601260045260245ffd5b7f4e487b71000000000000000000000000000000000000000000000000000000005f52602160045260245ffd5b5f60ff831680611584577f4e487b71000000000000000000000000000000000000000000000000000000005f52601260045260245ffd5b8060ff8416069150509291505056",
}

// FixtureVault is an auto generated Go binding around an Ethereum contract.
type FixtureVault struct {
	abi abi.ABI
}

// GetABI returns the ABI associated with this contract binding.
func (c *FixtureVault) GetABI() abi.ABI {
	return c.abi
}

// NewFixtureVault creates a new instance of FixtureVault.
func NewFixtureVault() *FixtureVault {
	parsed, err := FixtureVaultMetaData.ParseABI()
	if err != nil {
		panic(errors.New("invalid ABI: " + err.Error()))
	}
	return &FixtureVault{abi: *parsed}
}

// Instance creates a wrapper for a deployed contract instance at the given address.
// Use this to create the instance object passed to abigen v2 library functions Call, Transact, etc.
func (c *FixtureVault) Instance(backend bind.ContractBackend, addr common.Address) *bind.BoundContract {
	return bind.NewBoundContract(addr, c.abi, backend, backend, backend)
}

// PackConstructor is the Go binding used to pack the parameters required for
// contract deployment.
//
// Solidity: constructor(address asset_, string name_, string symbol_) returns()
func (fixtureVault *FixtureVault) PackConstructor(asset_ common.Address, name_ string, symbol_ string) []byte {
	enc, err := fixtureVault.abi.Pack("", asset_, name_, symbol_)
	if err != nil {
		panic(err)
	}
	return enc
}

// PackAllowance is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xdd62ed3e.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (fixtureVault *FixtureVault) PackAllowance(owner common.Address, spender common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("allowance", owner, spender)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackAllowance is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xdd62ed3e.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackAllowance(owner common.Address, spender common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("allowance", owner, spender)
}

// UnpackAllowance is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xdd62ed3e.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackAllowance(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("allowance", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackApprove is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x095ea7b3.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (fixtureVault *FixtureVault) PackApprove(spender common.Address, value *big.Int) []byte {
	enc, err := fixtureVault.abi.Pack("approve", spender, value)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackApprove is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x095ea7b3.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (fixtureVault *FixtureVault) TryPackApprove(spender common.Address, value *big.Int) ([]byte, error) {
	return fixtureVault.abi.Pack("approve", spender, value)
}

// UnpackApprove is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x095ea7b3.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (fixtureVault *FixtureVault) UnpackApprove(data []byte) (bool, error) {
	out, err := fixtureVault.abi.Unpack("approve", data)
	if err != nil {
		return *new(bool), err
	}
	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)
	return out0, nil
}

// PackAsset is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x38d52e0f.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function asset() view returns(address)
func (fixtureVault *FixtureVault) PackAsset() []byte {
	enc, err := fixtureVault.abi.Pack("asset")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackAsset is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x38d52e0f.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function asset() view returns(address)
func (fixtureVault *FixtureVault) TryPackAsset() ([]byte, error) {
	return fixtureVault.abi.Pack("asset")
}

// UnpackAsset is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x38d52e0f.
//
// Solidity: function asset() view returns(address)
func (fixtureVault *FixtureVault) UnpackAsset(data []byte) (common.Address, error) {
	out, err := fixtureVault.abi.Unpack("asset", data)
	if err != nil {
		return *new(common.Address), err
	}
	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)
	return out0, nil
}

// PackBalanceOf is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x70a08231.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (fixtureVault *FixtureVault) PackBalanceOf(account common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("balanceOf", account)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackBalanceOf is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x70a08231.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackBalanceOf(account common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("balanceOf", account)
}

// UnpackBalanceOf is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x70a08231.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackBalanceOf(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("balanceOf", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackConvertToAssets is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x07a2d13a.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function convertToAssets(uint256 shares) view returns(uint256)
func (fixtureVault *FixtureVault) PackConvertToAssets(shares *big.Int) []byte {
	enc, err := fixtureVault.abi.Pack("convertToAssets", shares)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackConvertToAssets is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x07a2d13a.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function convertToAssets(uint256 shares) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackConvertToAssets(shares *big.Int) ([]byte, error) {
	return fixtureVault.abi.Pack("convertToAssets", shares)
}

// UnpackConvertToAssets is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x07a2d13a.
//
// Solidity: function convertToAssets(uint256 shares) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackConvertToAssets(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("convertToAssets", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackConvertToShares is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xc6e6f592.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function convertToShares(uint256 assets) view returns(uint256)
func (fixtureVault *FixtureVault) PackConvertToShares(assets *big.Int) []byte {
	enc, err := fixtureVault.abi.Pack("convertToShares", assets)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackConvertToShares is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xc6e6f592.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function convertToShares(uint256 assets) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackConvertToShares(assets *big.Int) ([]byte, error) {
	return fixtureVault.abi.Pack("convertToShares", assets)
}

// UnpackConvertToShares is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xc6e6f592.
//
// Solidity: function convertToShares(uint256 assets) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackConvertToShares(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("convertToShares", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackDecimals is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x313ce567.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function decimals() view returns(uint8)
func (fixtureVault *FixtureVault) PackDecimals() []byte {
	enc, err := fixtureVault.abi.Pack("decimals")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackDecimals is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x313ce567.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function decimals() view returns(uint8)
func (fixtureVault *FixtureVault) TryPackDecimals() ([]byte, error) {
	return fixtureVault.abi.Pack("decimals")
}

// UnpackDecimals is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x313ce567.
//
// Solidity: function decimals() view returns(uint8)
func (fixtureVault *FixtureVault) UnpackDecimals(data []byte) (uint8, error) {
	out, err := fixtureVault.abi.Unpack("decimals", data)
	if err != nil {
		return *new(uint8), err
	}
	out0 := *abi.ConvertType(out[0], new(uint8)).(*uint8)
	return out0, nil
}

// PackDeposit is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x6e553f65.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function deposit(uint256 assets, address receiver) returns(uint256)
func (fixtureVault *FixtureVault) PackDeposit(assets *big.Int, receiver common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("deposit", assets, receiver)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackDeposit is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x6e553f65.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function deposit(uint256 assets, address receiver) returns(uint256)
func (fixtureVault *FixtureVault) TryPackDeposit(assets *big.Int, receiver common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("deposit", assets, receiver)
}

// UnpackDeposit is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x6e553f65.
//
// Solidity: function deposit(uint256 assets, address receiver) returns(uint256)
func (fixtureVault *FixtureVault) UnpackDeposit(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("deposit", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackMaxDeposit is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x402d267d.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function maxDeposit(address ) view returns(uint256)
func (fixtureVault *FixtureVault) PackMaxDeposit(arg0 common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("maxDeposit", arg0)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackMaxDeposit is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x402d267d.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function maxDeposit(address ) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackMaxDeposit(arg0 common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("maxDeposit", arg0)
}

// UnpackMaxDeposit is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x402d267d.
//
// Solidity: function maxDeposit(address ) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackMaxDeposit(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("maxDeposit", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackMaxMint is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xc63d75b6.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function maxMint(address ) view returns(uint256)
func (fixtureVault *FixtureVault) PackMaxMint(arg0 common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("maxMint", arg0)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackMaxMint is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xc63d75b6.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function maxMint(address ) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackMaxMint(arg0 common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("maxMint", arg0)
}

// UnpackMaxMint is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xc63d75b6.
//
// Solidity: function maxMint(address ) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackMaxMint(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("maxMint", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackMaxRedeem is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xd905777e.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function maxRedeem(address owner) view returns(uint256)
func (fixtureVault *FixtureVault) PackMaxRedeem(owner common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("maxRedeem", owner)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackMaxRedeem is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xd905777e.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function maxRedeem(address owner) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackMaxRedeem(owner common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("maxRedeem", owner)
}

// UnpackMaxRedeem is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xd905777e.
//
// Solidity: function maxRedeem(address owner) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackMaxRedeem(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("maxRedeem", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackMaxWithdraw is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xce96cb77.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function maxWithdraw(address owner) view returns(uint256)
func (fixtureVault *FixtureVault) PackMaxWithdraw(owner common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("maxWithdraw", owner)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackMaxWithdraw is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xce96cb77.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function maxWithdraw(address owner) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackMaxWithdraw(owner common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("maxWithdraw", owner)
}

// UnpackMaxWithdraw is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xce96cb77.
//
// Solidity: function maxWithdraw(address owner) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackMaxWithdraw(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("maxWithdraw", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackMint is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x94bf804d.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function mint(uint256 shares, address receiver) returns(uint256)
func (fixtureVault *FixtureVault) PackMint(shares *big.Int, receiver common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("mint", shares, receiver)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackMint is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x94bf804d.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function mint(uint256 shares, address receiver) returns(uint256)
func (fixtureVault *FixtureVault) TryPackMint(shares *big.Int, receiver common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("mint", shares, receiver)
}

// UnpackMint is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x94bf804d.
//
// Solidity: function mint(uint256 shares, address receiver) returns(uint256)
func (fixtureVault *FixtureVault) UnpackMint(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("mint", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackName is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x06fdde03.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function name() view returns(string)
func (fixtureVault *FixtureVault) PackName() []byte {
	enc, err := fixtureVault.abi.Pack("name")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackName is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x06fdde03.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function name() view returns(string)
func (fixtureVault *FixtureVault) TryPackName() ([]byte, error) {
	return fixtureVault.abi.Pack("name")
}

// UnpackName is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x06fdde03.
//
// Solidity: function name() view returns(string)
func (fixtureVault *FixtureVault) UnpackName(data []byte) (string, error) {
	out, err := fixtureVault.abi.Unpack("name", data)
	if err != nil {
		return *new(string), err
	}
	out0 := *abi.ConvertType(out[0], new(string)).(*string)
	return out0, nil
}

// PackPreviewDeposit is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xef8b30f7.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function previewDeposit(uint256 assets) view returns(uint256)
func (fixtureVault *FixtureVault) PackPreviewDeposit(assets *big.Int) []byte {
	enc, err := fixtureVault.abi.Pack("previewDeposit", assets)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackPreviewDeposit is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xef8b30f7.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function previewDeposit(uint256 assets) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackPreviewDeposit(assets *big.Int) ([]byte, error) {
	return fixtureVault.abi.Pack("previewDeposit", assets)
}

// UnpackPreviewDeposit is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xef8b30f7.
//
// Solidity: function previewDeposit(uint256 assets) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackPreviewDeposit(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("previewDeposit", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackPreviewMint is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xb3d7f6b9.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function previewMint(uint256 shares) view returns(uint256)
func (fixtureVault *FixtureVault) PackPreviewMint(shares *big.Int) []byte {
	enc, err := fixtureVault.abi.Pack("previewMint", shares)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackPreviewMint is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xb3d7f6b9.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function previewMint(uint256 shares) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackPreviewMint(shares *big.Int) ([]byte, error) {
	return fixtureVault.abi.Pack("previewMint", shares)
}

// UnpackPreviewMint is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xb3d7f6b9.
//
// Solidity: function previewMint(uint256 shares) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackPreviewMint(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("previewMint", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackPreviewRedeem is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x4cdad506.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function previewRedeem(uint256 shares) view returns(uint256)
func (fixtureVault *FixtureVault) PackPreviewRedeem(shares *big.Int) []byte {
	enc, err := fixtureVault.abi.Pack("previewRedeem", shares)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackPreviewRedeem is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x4cdad506.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function previewRedeem(uint256 shares) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackPreviewRedeem(shares *big.Int) ([]byte, error) {
	return fixtureVault.abi.Pack("previewRedeem", shares)
}

// UnpackPreviewRedeem is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x4cdad506.
//
// Solidity: function previewRedeem(uint256 shares) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackPreviewRedeem(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("previewRedeem", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackPreviewWithdraw is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x0a28a477.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function previewWithdraw(uint256 assets) view returns(uint256)
func (fixtureVault *FixtureVault) PackPreviewWithdraw(assets *big.Int) []byte {
	enc, err := fixtureVault.abi.Pack("previewWithdraw", assets)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackPreviewWithdraw is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x0a28a477.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function previewWithdraw(uint256 assets) view returns(uint256)
func (fixtureVault *FixtureVault) TryPackPreviewWithdraw(assets *big.Int) ([]byte, error) {
	return fixtureVault.abi.Pack("previewWithdraw", assets)
}

// UnpackPreviewWithdraw is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x0a28a477.
//
// Solidity: function previewWithdraw(uint256 assets) view returns(uint256)
func (fixtureVault *FixtureVault) UnpackPreviewWithdraw(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("previewWithdraw", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackRedeem is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xba087652.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function redeem(uint256 shares, address receiver, address owner) returns(uint256)
func (fixtureVault *FixtureVault) PackRedeem(shares *big.Int, receiver common.Address, owner common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("redeem", shares, receiver, owner)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackRedeem is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xba087652.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function redeem(uint256 shares, address receiver, address owner) returns(uint256)
func (fixtureVault *FixtureVault) TryPackRedeem(shares *big.Int, receiver common.Address, owner common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("redeem", shares, receiver, owner)
}

// UnpackRedeem is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xba087652.
//
// Solidity: function redeem(uint256 shares, address receiver, address owner) returns(uint256)
func (fixtureVault *FixtureVault) UnpackRedeem(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("redeem", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackSymbol is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x95d89b41.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function symbol() view returns(string)
func (fixtureVault *FixtureVault) PackSymbol() []byte {
	enc, err := fixtureVault.abi.Pack("symbol")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackSymbol is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x95d89b41.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function symbol() view returns(string)
func (fixtureVault *FixtureVault) TryPackSymbol() ([]byte, error) {
	return fixtureVault.abi.Pack("symbol")
}

// UnpackSymbol is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x95d89b41.
//
// Solidity: function symbol() view returns(string)
func (fixtureVault *FixtureVault) UnpackSymbol(data []byte) (string, error) {
	out, err := fixtureVault.abi.Unpack("symbol", data)
	if err != nil {
		return *new(string), err
	}
	out0 := *abi.ConvertType(out[0], new(string)).(*string)
	return out0, nil
}

// PackTotalAssets is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x01e1d114.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function totalAssets() view returns(uint256)
func (fixtureVault *FixtureVault) PackTotalAssets() []byte {
	enc, err := fixtureVault.abi.Pack("totalAssets")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackTotalAssets is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x01e1d114.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function totalAssets() view returns(uint256)
func (fixtureVault *FixtureVault) TryPackTotalAssets() ([]byte, error) {
	return fixtureVault.abi.Pack("totalAssets")
}

// UnpackTotalAssets is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x01e1d114.
//
// Solidity: function totalAssets() view returns(uint256)
func (fixtureVault *FixtureVault) UnpackTotalAssets(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("totalAssets", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackTotalSupply is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x18160ddd.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function totalSupply() view returns(uint256)
func (fixtureVault *FixtureVault) PackTotalSupply() []byte {
	enc, err := fixtureVault.abi.Pack("totalSupply")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackTotalSupply is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x18160ddd.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function totalSupply() view returns(uint256)
func (fixtureVault *FixtureVault) TryPackTotalSupply() ([]byte, error) {
	return fixtureVault.abi.Pack("totalSupply")
}

// UnpackTotalSupply is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x18160ddd.
//
// Solidity: function totalSupply() view returns(uint256)
func (fixtureVault *FixtureVault) UnpackTotalSupply(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("totalSupply", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackTransfer is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xa9059cbb.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (fixtureVault *FixtureVault) PackTransfer(to common.Address, value *big.Int) []byte {
	enc, err := fixtureVault.abi.Pack("transfer", to, value)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackTransfer is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xa9059cbb.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (fixtureVault *FixtureVault) TryPackTransfer(to common.Address, value *big.Int) ([]byte, error) {
	return fixtureVault.abi.Pack("transfer", to, value)
}

// UnpackTransfer is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xa9059cbb.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (fixtureVault *FixtureVault) UnpackTransfer(data []byte) (bool, error) {
	out, err := fixtureVault.abi.Unpack("transfer", data)
	if err != nil {
		return *new(bool), err
	}
	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)
	return out0, nil
}

// PackTransferFrom is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x23b872dd.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (fixtureVault *FixtureVault) PackTransferFrom(from common.Address, to common.Address, value *big.Int) []byte {
	enc, err := fixtureVault.abi.Pack("transferFrom", from, to, value)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackTransferFrom is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x23b872dd.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (fixtureVault *FixtureVault) TryPackTransferFrom(from common.Address, to common.Address, value *big.Int) ([]byte, error) {
	return fixtureVault.abi.Pack("transferFrom", from, to, value)
}

// UnpackTransferFrom is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x23b872dd.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (fixtureVault *FixtureVault) UnpackTransferFrom(data []byte) (bool, error) {
	out, err := fixtureVault.abi.Unpack("transferFrom", data)
	if err != nil {
		return *new(bool), err
	}
	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)
	return out0, nil
}

// PackWithdraw is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xb460af94.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function withdraw(uint256 assets, address receiver, address owner) returns(uint256)
func (fixtureVault *FixtureVault) PackWithdraw(assets *big.Int, receiver common.Address, owner common.Address) []byte {
	enc, err := fixtureVault.abi.Pack("withdraw", assets, receiver, owner)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackWithdraw is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xb460af94.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function withdraw(uint256 assets, address receiver, address owner) returns(uint256)
func (fixtureVault *FixtureVault) TryPackWithdraw(assets *big.Int, receiver common.Address, owner common.Address) ([]byte, error) {
	return fixtureVault.abi.Pack("withdraw", assets, receiver, owner)
}

// UnpackWithdraw is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xb460af94.
//
// Solidity: function withdraw(uint256 assets, address receiver, address owner) returns(uint256)
func (fixtureVault *FixtureVault) UnpackWithdraw(data []byte) (*big.Int, error) {
	out, err := fixtureVault.abi.Unpack("withdraw", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// FixtureVaultApproval represents a Approval event raised by the FixtureVault contract.
type FixtureVaultApproval struct {
	Owner   common.Address
	Spender common.Address
	Value   *big.Int
	Raw     *types.Log // Blockchain specific contextual infos
}

const FixtureVaultApprovalEventName = "Approval"

// ContractEventName returns the user-defined event name.
func (FixtureVaultApproval) ContractEventName() string {
	return FixtureVaultApprovalEventName
}

// UnpackApprovalEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event Approval(address indexed owner, address indexed spender, uint256 value)
func (fixtureVault *FixtureVault) UnpackApprovalEvent(log *types.Log) (*FixtureVaultApproval, error) {
	event := "Approval"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != fixtureVault.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(FixtureVaultApproval)
	if len(log.Data) > 0 {
		if err := fixtureVault.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range fixtureVault.abi.Events[event].Inputs {
		if arg.Indexed {
			indexed = append(indexed, arg)
		}
	}
	if err := abi.ParseTopics(out, indexed, log.Topics[1:]); err != nil {
		return nil, err
	}
	out.Raw = log
	return out, nil
}

// FixtureVaultDeposit represents a Deposit event raised by the FixtureVault contract.
type FixtureVaultDeposit struct {
	Sender common.Address
	Owner  common.Address
	Assets *big.Int
	Shares *big.Int
	Raw    *types.Log // Blockchain specific contextual infos
}

const FixtureVaultDepositEventName = "Deposit"

// ContractEventName returns the user-defined event name.
func (FixtureVaultDeposit) ContractEventName() string {
	return FixtureVaultDepositEventName
}

// UnpackDepositEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)
func (fixtureVault *FixtureVault) UnpackDepositEvent(log *types.Log) (*FixtureVaultDeposit, error) {
	event := "Deposit"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != fixtureVault.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(FixtureVaultDeposit)
	if len(log.Data) > 0 {
		if err := fixtureVault.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range fixtureVault.abi.Events[event].Inputs {
		if arg.Indexed {
			indexed = append(indexed, arg)
		}
	}
	if err := abi.ParseTopics(out, indexed, log.Topics[1:]); err != nil {
		return nil, err
	}
	out.Raw = log
	return out, nil
}

// FixtureVaultTransfer represents a Transfer event raised by the FixtureVault contract.
type FixtureVaultTransfer struct {
	From  common.Address
	To    common.Address
	Value *big.Int
	Raw   *types.Log // Blockchain specific contextual infos
}

const FixtureVaultTransferEventName = "Transfer"

// ContractEventName returns the user-defined event name.
func (FixtureVaultTransfer) ContractEventName() string {
	return FixtureVaultTransferEventName
}

// UnpackTransferEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event Transfer(address indexed from, address indexed to, uint256 value)
func (fixtureVault *FixtureVault) UnpackTransferEvent(log *types.Log) (*FixtureVaultTransfer, error) {
	event := "Transfer"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != fixtureVault.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(FixtureVaultTransfer)
	if len(log.Data) > 0 {
		if err := fixtureVault.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range fixtureVault.abi.Events[event].Inputs {
		if arg.Indexed {
			indexed = append(indexed, arg)
		}
	}
	if err := abi.ParseTopics(out, indexed, log.Topics[1:]); err != nil {
		return nil, err
	}
	out.Raw = log
	return out, nil
}

// FixtureVaultWithdraw represents a Withdraw event raised by the FixtureVault contract.
type FixtureVaultWithdraw struct {
	Sender   common.Address
	Receiver common.Address
	Owner    common.Address
	Assets   *big.Int
	Shares   *big.Int
	Raw      *types.Log // Blockchain specific contextual infos
}

const FixtureVaultWithdrawEventName = "Withdraw"

// ContractEventName returns the user-defined event name.
func (FixtureVaultWithdraw) ContractEventName() string {
	return FixtureVaultWithdrawEventName
}

// UnpackWithdrawEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)
func (fixtureVault *FixtureVault) UnpackWithdrawEvent(log *types.Log) (*FixtureVaultWithdraw, error) {
	event := "Withdraw"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != fixtureVault.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(FixtureVaultWithdraw)
	if len(log.Data) > 0 {
		if err := fixtureVault.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range fixtureVault.abi.Events[event].Inputs {
		if arg.Indexed {
			indexed = append(indexed, arg)
		}
	}
	if err := abi.ParseTopics(out, indexed, log.Topics[1:]); err != nil {
		return nil, err
	}
	out.Raw = log
	return out, nil
}

// UnpackError attempts to decode the provided error data using user-defined
// error definitions.
func (fixtureVault *FixtureVault) UnpackError(raw []byte) (any, error) {
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC20InsufficientAllowance"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC20InsufficientAllowanceError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC20InsufficientBalance"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC20InsufficientBalanceError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC20InvalidApprover"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC20InvalidApproverError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC20InvalidReceiver"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC20InvalidReceiverError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC20InvalidSender"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC20InvalidSenderError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC20InvalidSpender"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC20InvalidSpenderError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC4626ExceededMaxDeposit"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC4626ExceededMaxDepositError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC4626ExceededMaxMint"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC4626ExceededMaxMintError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC4626ExceededMaxRedeem"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC4626ExceededMaxRedeemError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["ERC4626ExceededMaxWithdraw"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackERC4626ExceededMaxWithdrawError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureVault.abi.Errors["SafeERC20FailedOperation"].ID.Bytes()[:4]) {
		return fixtureVault.UnpackSafeERC20FailedOperationError(raw[4:])
	}
	return nil, errors.New("Unknown error")
}

// FixtureVaultERC20InsufficientAllowance represents a ERC20InsufficientAllowance error raised by the FixtureVault contract.
type FixtureVaultERC20InsufficientAllowance struct {
	Spender   common.Address
	Allowance *big.Int
	Needed    *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)
func FixtureVaultERC20InsufficientAllowanceErrorID() common.Hash {
	return common.HexToHash("0xfb8f41b23e99d2101d86da76cdfa87dd51c82ed07d3cb62cbc473e469dbc75c3")
}

// UnpackERC20InsufficientAllowanceError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)
func (fixtureVault *FixtureVault) UnpackERC20InsufficientAllowanceError(raw []byte) (*FixtureVaultERC20InsufficientAllowance, error) {
	out := new(FixtureVaultERC20InsufficientAllowance)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC20InsufficientAllowance", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultERC20InsufficientBalance represents a ERC20InsufficientBalance error raised by the FixtureVault contract.
type FixtureVaultERC20InsufficientBalance struct {
	Sender  common.Address
	Balance *big.Int
	Needed  *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)
func FixtureVaultERC20InsufficientBalanceErrorID() common.Hash {
	return common.HexToHash("0xe450d38cd8d9f7d95077d567d60ed49c7254716e6ad08fc9872816c97e0ffec6")
}

// UnpackERC20InsufficientBalanceError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)
func (fixtureVault *FixtureVault) UnpackERC20InsufficientBalanceError(raw []byte) (*FixtureVaultERC20InsufficientBalance, error) {
	out := new(FixtureVaultERC20InsufficientBalance)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC20InsufficientBalance", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultERC20InvalidApprover represents a ERC20InvalidApprover error raised by the FixtureVault contract.
type FixtureVaultERC20InvalidApprover struct {
	Approver common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidApprover(address approver)
func FixtureVaultERC20InvalidApproverErrorID() common.Hash {
	return common.HexToHash("0xe602df05cc75712490294c6c104ab7c17f4030363910a7a2626411c6d3118847")
}

// UnpackERC20InvalidApproverError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidApprover(address approver)
func (fixtureVault *FixtureVault) UnpackERC20InvalidApproverError(raw []byte) (*FixtureVaultERC20InvalidApprover, error) {
	out := new(FixtureVaultERC20InvalidApprover)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC20InvalidApprover", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultERC20InvalidReceiver represents a ERC20InvalidReceiver error raised by the FixtureVault contract.
type FixtureVaultERC20InvalidReceiver struct {
	Receiver common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidReceiver(address receiver)
func FixtureVaultERC20InvalidReceiverErrorID() common.Hash {
	return common.HexToHash("0xec442f055133b72f3b2f9f0bb351c406b178527de2040a7d1feb4e058771f613")
}

// UnpackERC20InvalidReceiverError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidReceiver(address receiver)
func (fixtureVault *FixtureVault) UnpackERC20InvalidReceiverError(raw []byte) (*FixtureVaultERC20InvalidReceiver, error) {
	out := new(FixtureVaultERC20InvalidReceiver)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC20InvalidReceiver", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultERC20InvalidSender represents a ERC20InvalidSender error raised by the FixtureVault contract.
type FixtureVaultERC20InvalidSender struct {
	Sender common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidSender(address sender)
func FixtureVaultERC20InvalidSenderErrorID() common.Hash {
	return common.HexToHash("0x96c6fd1edd0cd6ef7ff0ecc0facdf53148dc0048b57fe58af65755250a7a96bd")
}

// UnpackERC20InvalidSenderError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidSender(address sender)
func (fixtureVault *FixtureVault) UnpackERC20InvalidSenderError(raw []byte) (*FixtureVaultERC20InvalidSender, error) {
	out := new(FixtureVaultERC20InvalidSender)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC20InvalidSender", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultERC20InvalidSpender represents a ERC20InvalidSpender error raised by the FixtureVault contract.
type FixtureVaultERC20InvalidSpender struct {
	Spender common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidSpender(address spender)
func FixtureVaultERC20InvalidSpenderErrorID() common.Hash {
	return common.HexToHash("0x94280d62c347d8d9f4d59a76ea321452406db88df38e0c9da304f58b57b373a2")
}

// UnpackERC20InvalidSpenderError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidSpender(address spender)
func (fixtureVault *FixtureVault) UnpackERC20InvalidSpenderError(raw []byte) (*FixtureVaultERC20InvalidSpender, error) {
	out := new(FixtureVaultERC20InvalidSpender)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC20InvalidSpender", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultERC4626ExceededMaxDeposit represents a ERC4626ExceededMaxDeposit error raised by the FixtureVault contract.
type FixtureVaultERC4626ExceededMaxDeposit struct {
	Receiver common.Address
	Assets   *big.Int
	Max      *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max)
func FixtureVaultERC4626ExceededMaxDepositErrorID() common.Hash {
	return common.HexToHash("0x79012fb2819fcdc1de669c08773dbcd6bdc757862642f75fb1c584dadf259dfe")
}

// UnpackERC4626ExceededMaxDepositError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max)
func (fixtureVault *FixtureVault) UnpackERC4626ExceededMaxDepositError(raw []byte) (*FixtureVaultERC4626ExceededMaxDeposit, error) {
	out := new(FixtureVaultERC4626ExceededMaxDeposit)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC4626ExceededMaxDeposit", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultERC4626ExceededMaxMint represents a ERC4626ExceededMaxMint error raised by the FixtureVault contract.
type FixtureVaultERC4626ExceededMaxMint struct {
	Receiver common.Address
	Shares   *big.Int
	Max      *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max)
func FixtureVaultERC4626ExceededMaxMintErrorID() common.Hash {
	return common.HexToHash("0x284ff667dc615a39438518c22e8955b9470327d9de8a4d7e21c926b260d65176")
}

// UnpackERC4626ExceededMaxMintError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max)
func (fixtureVault *FixtureVault) UnpackERC4626ExceededMaxMintError(raw []byte) (*FixtureVaultERC4626ExceededMaxMint, error) {
	out := new(FixtureVaultERC4626ExceededMaxMint)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC4626ExceededMaxMint", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultERC4626ExceededMaxRedeem represents a ERC4626ExceededMaxRedeem error raised by the FixtureVault contract.
type FixtureVaultERC4626ExceededMaxRedeem struct {
	Owner  common.Address
	Shares *big.Int
	Max    *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max)
func FixtureVaultERC4626ExceededMaxRedeemErrorID() common.Hash {
	return common.HexToHash("0xb94abeec0557d36b5f0bc8f115deec7b184dcbff94ac66d55e37c8f301e75269")
}

// UnpackERC4626ExceededMaxRedeemError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max)
func (fixtureVault *FixtureVault) UnpackERC4626ExceededMaxRedeemError(raw []byte) (*FixtureVaultERC4626ExceededMaxRedeem, error) {
	out := new(FixtureVaultERC4626ExceededMaxRedeem)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC4626ExceededMaxRedeem", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultERC4626ExceededMaxWithdraw represents a ERC4626ExceededMaxWithdraw error raised by the FixtureVault contract.
type FixtureVaultERC4626ExceededMaxWithdraw struct {
	Owner  common.Address
	Assets *big.Int
	Max    *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max)
func FixtureVaultERC4626ExceededMaxWithdrawErrorID() common.Hash {
	return common.HexToHash("0xfe9cceec2bd1f9b68641914cc354eacaeb1cc2169f5ba0639930f241e87142f0")
}

// UnpackERC4626ExceededMaxWithdrawError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max)
func (fixtureVault *FixtureVault) UnpackERC4626ExceededMaxWithdrawError(raw []byte) (*FixtureVaultERC4626ExceededMaxWithdraw, error) {
	out := new(FixtureVaultERC4626ExceededMaxWithdraw)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "ERC4626ExceededMaxWithdraw", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureVaultSafeERC20FailedOperation represents a SafeERC20FailedOperation error raised by the FixtureVault contract.
type FixtureVaultSafeERC20FailedOperation struct {
	Token common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error SafeERC20FailedOperation(address token)
func FixtureVaultSafeERC20FailedOperationErrorID() common.Hash {
	return common.HexToHash("0x5274afe73c98b4749fc91ffae6b7b574e7842cb2144a159e9377a5f20b32edf9")
}

// UnpackSafeERC20FailedOperationError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error SafeERC20FailedOperation(address token)
func (fixtureVault *FixtureVault) UnpackSafeERC20FailedOperationError(raw []byte) (*FixtureVaultSafeERC20FailedOperation, error) {
	out := new(FixtureVaultSafeERC20FailedOperation)
	if err := fixtureVault.abi.UnpackIntoInterface(out, "SafeERC20FailedOperation", raw); err != nil {
		return nil, err
	}
	return out, nil
}
