// Code generated - DO NOT EDIT.
// This file is a generated binding and any manual changes will be lost.

package bindings

import (
	"context"
	"errors"
	"math/big"
	"strings"
	"time"

	ethereum "github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/event"
)

// Reference imports to suppress errors if they are not otherwise used.
var (
	_ = errors.New
	_ = big.NewInt
	_ = strings.NewReader
	_ = ethereum.NotFound
	_ = bind.Bind
	_ = common.Big1
	_ = types.BloomLookup
	_ = event.NewSubscription
	_ = abi.ConvertType
	_ = time.Tick
	_ = context.Background
)

// ILPVaultLpRequest is an auto generated low-level Go binding around an user-defined struct.
type ILPVaultLpRequest struct {
	Account      common.Address
	IsDeposit    bool
	CreatedAt    uint64
	Amount       *big.Int
	MinOut       *big.Int
	ExecutionFee *big.Int
}

// IOracleVerifierSignedPriceReport is an auto generated low-level Go binding around an user-defined struct.
type IOracleVerifierSignedPriceReport struct {
	Signer    common.Address
	Price     *big.Int
	Timestamp uint64
	Signature []byte
}

// IOrderBookOrder is an auto generated low-level Go binding around an user-defined struct.
type IOrderBookOrder struct {
	Account         common.Address
	OrderType       uint8
	IsLong          bool
	CreatedAt       uint64
	SizeDeltaUsd    *big.Int
	CollateralDelta *big.Int
	TriggerPrice    *big.Int
	AcceptablePrice *big.Int
	ExecutionFee    *big.Int
}

// IPerpsMarketMarketStats is an auto generated low-level Go binding around an user-defined struct.
type IPerpsMarketMarketStats struct {
	PositionFees         *big.Int
	BorrowFees           *big.Int
	FundingPaidByTraders *big.Int
	FundingPaidToTraders *big.Int
	TraderLosses         *big.Int
	TraderProfits        *big.Int
	BadDebt              *big.Int
	KeeperFees           *big.Int
	ImpactCollected      *big.Int
	ImpactPaid           *big.Int
	LpDeposited          *big.Int
	LpWithdrawn          *big.Int
	Liquidations         *big.Int
	AutoDeleverages      *big.Int
	Haircuts             *big.Int
	ImpactDistributed    *big.Int
}

// IPerpsMarketPosition is an auto generated low-level Go binding around an user-defined struct.
type IPerpsMarketPosition struct {
	SizeUsd           *big.Int
	SizeInTokens      *big.Int
	Collateral        *big.Int
	LastUpdatedAt     uint64
	BorrowIndexEntry  *big.Int
	FundingIndexEntry *big.Int
}

// IPerpsMarketPositionInfo is an auto generated low-level Go binding around an user-defined struct.
type IPerpsMarketPositionInfo struct {
	Pnl                 *big.Int
	BorrowFee           *big.Int
	FundingFee          *big.Int
	CloseFee            *big.Int
	RemainingCollateral *big.Int
	MaintenanceMargin   *big.Int
	Liquidatable        bool
}

// IPerpsMarketRiskParams is an auto generated low-level Go binding around an user-defined struct.
type IPerpsMarketRiskParams struct {
	MaxLongOpenInterest  *big.Int
	MaxShortOpenInterest *big.Int
	ReserveFactor        uint64
	MaxPnlFactor         uint64
	AdlThresholdFactor   uint64
	AdlTargetFactor      uint64
	PositionFeeBps       uint16
	InitialMarginBps     uint16
	MaintenanceMarginBps uint16
	LiquidationFeeBps    uint16
	OrderTimeout         uint32
	MinCollateral        *big.Int
	PositiveImpactFactor *big.Int
	NegativeImpactFactor *big.Int
	BorrowFactor         uint64
	MaxFundingVelocity   uint64
	MaxFundingRate       uint64
	SkewScale            *big.Int
	MinExecutionFee      *big.Int
}

// IPerpsMarketSideState is an auto generated low-level Go binding around an user-defined struct.
type IPerpsMarketSideState struct {
	OpenInterest         *big.Int
	OpenInterestInTokens *big.Int
	BorrowIndex          *big.Int
	BorrowEntrySum       *big.Int
	FundingEntrySum      *big.Int
}

// AccessManagerMetaData contains all meta data concerning the AccessManager contract.
var AccessManagerMetaData = &bind.MetaData{
	ABI: "[{\"inputs\":[{\"internalType\":\"address\",\"name\":\"initialAdmin\",\"type\":\"address\"}],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"inputs\":[],\"name\":\"ADMIN_ROLE\",\"outputs\":[{\"internalType\":\"uint64\",\"name\":\"\",\"type\":\"uint64\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"PUBLIC_ROLE\",\"outputs\":[{\"internalType\":\"uint64\",\"name\":\"\",\"type\":\"uint64\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bytes4\",\"name\":\"selector\",\"type\":\"bytes4\"}],\"name\":\"canCall\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"immediate\",\"type\":\"bool\"},{\"internalType\":\"uint32\",\"name\":\"delay\",\"type\":\"uint32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bytes\",\"name\":\"data\",\"type\":\"bytes\"}],\"name\":\"cancel\",\"outputs\":[{\"internalType\":\"uint32\",\"name\":\"\",\"type\":\"uint32\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"bytes\",\"name\":\"data\",\"type\":\"bytes\"}],\"name\":\"consumeScheduledOp\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bytes\",\"name\":\"data\",\"type\":\"bytes\"}],\"name\":\"execute\",\"outputs\":[{\"internalType\":\"uint32\",\"name\":\"\",\"type\":\"uint32\"}],\"stateMutability\":\"payable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"expiration\",\"outputs\":[{\"internalType\":\"uint32\",\"name\":\"\",\"type\":\"uint32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"getAccess\",\"outputs\":[{\"internalType\":\"uint48\",\"name\":\"since\",\"type\":\"uint48\"},{\"internalType\":\"uint32\",\"name\":\"currentDelay\",\"type\":\"uint32\"},{\"internalType\":\"uint32\",\"name\":\"pendingDelay\",\"type\":\"uint32\"},{\"internalType\":\"uint48\",\"name\":\"effect\",\"type\":\"uint48\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"id\",\"type\":\"bytes32\"}],\"name\":\"getNonce\",\"outputs\":[{\"internalType\":\"uint32\",\"name\":\"\",\"type\":\"uint32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"}],\"name\":\"getRoleAdmin\",\"outputs\":[{\"internalType\":\"uint64\",\"name\":\"\",\"type\":\"uint64\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"}],\"name\":\"getRoleGrantDelay\",\"outputs\":[{\"internalType\":\"uint32\",\"name\":\"\",\"type\":\"uint32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"}],\"name\":\"getRoleGuardian\",\"outputs\":[{\"internalType\":\"uint64\",\"name\":\"\",\"type\":\"uint64\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"id\",\"type\":\"bytes32\"}],\"name\":\"getSchedule\",\"outputs\":[{\"internalType\":\"uint48\",\"name\":\"\",\"type\":\"uint48\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"}],\"name\":\"getTargetAdminDelay\",\"outputs\":[{\"internalType\":\"uint32\",\"name\":\"\",\"type\":\"uint32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bytes4\",\"name\":\"selector\",\"type\":\"bytes4\"}],\"name\":\"getTargetFunctionRole\",\"outputs\":[{\"internalType\":\"uint64\",\"name\":\"\",\"type\":\"uint64\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"internalType\":\"uint32\",\"name\":\"executionDelay\",\"type\":\"uint32\"}],\"name\":\"grantRole\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"hasRole\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"isMember\",\"type\":\"bool\"},{\"internalType\":\"uint32\",\"name\":\"executionDelay\",\"type\":\"uint32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bytes\",\"name\":\"data\",\"type\":\"bytes\"}],\"name\":\"hashOperation\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"}],\"name\":\"isTargetClosed\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"internalType\":\"string\",\"name\":\"label\",\"type\":\"string\"}],\"name\":\"labelRole\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"minSetback\",\"outputs\":[{\"internalType\":\"uint32\",\"name\":\"\",\"type\":\"uint32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes[]\",\"name\":\"data\",\"type\":\"bytes[]\"}],\"name\":\"multicall\",\"outputs\":[{\"internalType\":\"bytes[]\",\"name\":\"results\",\"type\":\"bytes[]\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"internalType\":\"address\",\"name\":\"callerConfirmation\",\"type\":\"address\"}],\"name\":\"renounceRole\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"revokeRole\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bytes\",\"name\":\"data\",\"type\":\"bytes\"},{\"internalType\":\"uint48\",\"name\":\"when\",\"type\":\"uint48\"}],\"name\":\"schedule\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"operationId\",\"type\":\"bytes32\"},{\"internalType\":\"uint32\",\"name\":\"nonce\",\"type\":\"uint32\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"internalType\":\"uint32\",\"name\":\"newDelay\",\"type\":\"uint32\"}],\"name\":\"setGrantDelay\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"admin\",\"type\":\"uint64\"}],\"name\":\"setRoleAdmin\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"guardian\",\"type\":\"uint64\"}],\"name\":\"setRoleGuardian\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"uint32\",\"name\":\"newDelay\",\"type\":\"uint32\"}],\"name\":\"setTargetAdminDelay\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bool\",\"name\":\"closed\",\"type\":\"bool\"}],\"name\":\"setTargetClosed\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bytes4[]\",\"name\":\"selectors\",\"type\":\"bytes4[]\"},{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"}],\"name\":\"setTargetFunctionRole\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"newAuthority\",\"type\":\"address\"}],\"name\":\"updateAuthority\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"bytes32\",\"name\":\"operationId\",\"type\":\"bytes32\"},{\"indexed\":true,\"internalType\":\"uint32\",\"name\":\"nonce\",\"type\":\"uint32\"}],\"name\":\"OperationCanceled\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"bytes32\",\"name\":\"operationId\",\"type\":\"bytes32\"},{\"indexed\":true,\"internalType\":\"uint32\",\"name\":\"nonce\",\"type\":\"uint32\"}],\"name\":\"OperationExecuted\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"bytes32\",\"name\":\"operationId\",\"type\":\"bytes32\"},{\"indexed\":true,\"internalType\":\"uint32\",\"name\":\"nonce\",\"type\":\"uint32\"},{\"indexed\":false,\"internalType\":\"uint48\",\"name\":\"schedule\",\"type\":\"uint48\"},{\"indexed\":false,\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"bytes\",\"name\":\"data\",\"type\":\"bytes\"}],\"name\":\"OperationScheduled\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"indexed\":true,\"internalType\":\"uint64\",\"name\":\"admin\",\"type\":\"uint64\"}],\"name\":\"RoleAdminChanged\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"indexed\":false,\"internalType\":\"uint32\",\"name\":\"delay\",\"type\":\"uint32\"},{\"indexed\":false,\"internalType\":\"uint48\",\"name\":\"since\",\"type\":\"uint48\"}],\"name\":\"RoleGrantDelayChanged\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint32\",\"name\":\"delay\",\"type\":\"uint32\"},{\"indexed\":false,\"internalType\":\"uint48\",\"name\":\"since\",\"type\":\"uint48\"},{\"indexed\":false,\"internalType\":\"bool\",\"name\":\"newMember\",\"type\":\"bool\"}],\"name\":\"RoleGranted\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"indexed\":true,\"internalType\":\"uint64\",\"name\":\"guardian\",\"type\":\"uint64\"}],\"name\":\"RoleGuardianChanged\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"indexed\":false,\"internalType\":\"string\",\"name\":\"label\",\"type\":\"string\"}],\"name\":\"RoleLabel\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"RoleRevoked\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint32\",\"name\":\"delay\",\"type\":\"uint32\"},{\"indexed\":false,\"internalType\":\"uint48\",\"name\":\"since\",\"type\":\"uint48\"}],\"name\":\"TargetAdminDelayUpdated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"bool\",\"name\":\"closed\",\"type\":\"bool\"}],\"name\":\"TargetClosed\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"bytes4\",\"name\":\"selector\",\"type\":\"bytes4\"},{\"indexed\":true,\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"}],\"name\":\"TargetFunctionRoleUpdated\",\"type\":\"event\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"operationId\",\"type\":\"bytes32\"}],\"name\":\"AccessManagerAlreadyScheduled\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"AccessManagerBadConfirmation\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"operationId\",\"type\":\"bytes32\"}],\"name\":\"AccessManagerExpired\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"initialAdmin\",\"type\":\"address\"}],\"name\":\"AccessManagerInvalidInitialAdmin\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"bytes4\",\"name\":\"selector\",\"type\":\"bytes4\"}],\"name\":\"AccessManagerLockedFunction\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"}],\"name\":\"AccessManagerLockedRole\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"operationId\",\"type\":\"bytes32\"}],\"name\":\"AccessManagerNotReady\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"operationId\",\"type\":\"bytes32\"}],\"name\":\"AccessManagerNotScheduled\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"msgsender\",\"type\":\"address\"},{\"internalType\":\"uint64\",\"name\":\"roleId\",\"type\":\"uint64\"}],\"name\":\"AccessManagerUnauthorizedAccount\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bytes4\",\"name\":\"selector\",\"type\":\"bytes4\"}],\"name\":\"AccessManagerUnauthorizedCall\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"msgsender\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"},{\"internalType\":\"bytes4\",\"name\":\"selector\",\"type\":\"bytes4\"}],\"name\":\"AccessManagerUnauthorizedCancel\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"}],\"name\":\"AccessManagerUnauthorizedConsume\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"target\",\"type\":\"address\"}],\"name\":\"AddressEmptyCode\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"FailedCall\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"balance\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"needed\",\"type\":\"uint256\"}],\"name\":\"InsufficientBalance\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint8\",\"name\":\"bits\",\"type\":\"uint8\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"SafeCastOverflowedUintDowncast\",\"type\":\"error\"}]",
	Bin: "0x608060405234801561000f575f5ffd5b50604051612d96380380612d9683398101604081905261002e91610441565b6001600160a01b03811661005c57604051630409d6d160e11b81525f60048201526024015b60405180910390fd5b6100685f82818061006f565b50506104bc565b5f6002600160401b03196001600160401b038616016100ac5760405163061c6a4360e21b81526001600160401b0386166004820152602401610053565b6001600160401b0385165f9081526001602090815260408083206001600160a01b038816845290915281205465ffffffffffff16159081156101a15763ffffffff85166100f76102b5565b6101019190610482565b905060405180604001604052808265ffffffffffff1681526020016101318663ffffffff166102c460201b60201c565b6001600160701b039081169091526001600160401b0389165f9081526001602090815260408083206001600160a01b038c16845282529091208351815494909201519092166601000000000000026001600160a01b031990931665ffffffffffff90911617919091179055610247565b6001600160401b0387165f9081526001602090815260408083206001600160a01b038a1684529091528120546101ed9166010000000000009091046001600160701b03169086906102cd565b6001600160401b0389165f9081526001602090815260408083206001600160a01b038c168452909152902080546001600160701b03909316660100000000000002600160301b600160a01b03199093169290921790915590505b6040805163ffffffff8616815265ffffffffffff831660208201528315158183015290516001600160a01b038816916001600160401b038a16917ff98448b987f1428e0e230e1f3c6e2ce15b5693eaf31827fbd0b1ec4b424ae7cf9181900360600190a35095945050505050565b5f6102bf42610373565b905090565b63ffffffff1690565b5f80806102e26001600160701b0387166103a9565b90505f61031d8563ffffffff168763ffffffff168463ffffffff1611610308575f610312565b61031288856104a0565b63ffffffff166103c7565b905063ffffffff811661032e6102b5565b6103389190610482565b925063ffffffff8616602083901b67ffffffff0000000016604085901b6dffffffffffff000000000000000016171793505050935093915050565b5f65ffffffffffff8211156103a5576040516306dfcc6560e41b81526030600482015260248101839052604401610053565b5090565b5f806103bd6001600160701b0384166103d7565b5090949350505050565b8082118183180281185b92915050565b5f80806103eb846103e66102b5565b6103f8565b9250925092509193909250565b6001600160501b03602083901c166001600160701b03831665ffffffffffff604085901c811690841681111561043057828282610434565b815f5f5b9250925092509250925092565b5f60208284031215610451575f5ffd5b81516001600160a01b0381168114610467575f5ffd5b9392505050565b634e487b7160e01b5f52601160045260245ffd5b65ffffffffffff81811683821601908111156103d1576103d161046e565b63ffffffff82811682821603908111156103d1576103d161046e565b6128cd806104c95f395ff3fe6080604052600436106101db575f3560e01c80636d5115bd116100fd578063b700961311610092578063d22b598911610062578063d22b598914610636578063d6bb62c614610655578063f801a69814610674578063fe0776f5146106ad575f5ffd5b8063b7009613146105a8578063b7d2b162146105e3578063cc1b6c8114610602578063d1f856ee14610617575f5ffd5b8063a166aa89116100cd578063a166aa8914610501578063a64d95ce14610530578063abd9bd2a1461054f578063ac9650d81461057c575f5ffd5b80636d5115bd1461049157806375b238fc146104b0578063853551b8146104c357806394c7d7ee146104e2575f5ffd5b806330cae187116101735780634665096d116101435780634665096d146104035780634c1da1e2146104185780635296295214610437578063530dd45614610456575f5ffd5b806330cae1871461035c5780633adc277a1461037b5780633ca7c02a146103b15780634136a33c146103cb575f5ffd5b806318ff183c116101ae57806318ff183c146102b25780631cff79cd146102d157806325c471a0146102e45780633078f11414610303575f5ffd5b806308d6122d146101df5780630b0a93ba1461020057806312be87271461025f578063167bd39514610293575b5f5ffd5b3480156101ea575f5ffd5b506101fe6101f93660046121f1565b6106cc565b005b34801561020b575f5ffd5b5061024261021a366004612253565b6001600160401b039081165f9081526001602081905260409091200154600160401b90041690565b6040516001600160401b0390911681526020015b60405180910390f35b34801561026a575f5ffd5b5061027e610279366004612253565b61071e565b60405163ffffffff9091168152602001610256565b34801561029e575f5ffd5b506101fe6102ad36600461226c565b610758565b3480156102bd575f5ffd5b506101fe6102cc3660046122a7565b61076e565b61027e6102df366004612310565b6107d0565b3480156102ef575f5ffd5b506101fe6102fe366004612373565b6108fc565b34801561030e575f5ffd5b5061032261031d3660046123b5565b61091e565b604051610256949392919065ffffffffffff948516815263ffffffff93841660208201529190921660408201529116606082015260800190565b348015610367575f5ffd5b506101fe6103763660046123cf565b610982565b348015610386575f5ffd5b5061039a610395366004612400565b610994565b60405165ffffffffffff9091168152602001610256565b3480156103bc575f5ffd5b506102426001600160401b0381565b3480156103d6575f5ffd5b5061027e6103e5366004612400565b5f90815260026020526040902054600160301b900463ffffffff1690565b34801561040e575f5ffd5b5062093a8061027e565b348015610423575f5ffd5b5061027e610432366004612417565b6109c5565b348015610442575f5ffd5b506101fe6104513660046123cf565b6109f2565b348015610461575f5ffd5b50610242610470366004612253565b6001600160401b039081165f90815260016020819052604090912001541690565b34801561049c575f5ffd5b506102426104ab366004612447565b610a04565b3480156104bb575f5ffd5b506102425f81565b3480156104ce575f5ffd5b506101fe6104dd366004612473565b610a3e565b3480156104ed575f5ffd5b506101fe6104fc366004612310565b610ad5565b34801561050c575f5ffd5b5061052061051b366004612417565b610b7f565b6040519015158152602001610256565b34801561053b575f5ffd5b506101fe61054a36600461248e565b610ba6565b34801561055a575f5ffd5b5061056e6105693660046124b6565b610bb8565b604051908152602001610256565b348015610587575f5ffd5b5061059b610596366004612516565b610bf1565b6040516102569190612554565b3480156105b3575f5ffd5b506105c76105c23660046125d8565b610cd6565b60408051921515835263ffffffff909116602083015201610256565b3480156105ee575f5ffd5b506101fe6105fd3660046123b5565b610dc7565b34801561060d575f5ffd5b506206978061027e565b348015610622575f5ffd5b506105c76106313660046123b5565b610dde565b348015610641575f5ffd5b506101fe610650366004612620565b610e57565b348015610660575f5ffd5b5061027e61066f3660046124b6565b610e69565b34801561067f575f5ffd5b5061069361068e36600461263c565b610f77565b6040805192835263ffffffff909116602083015201610256565b3480156106b8575f5ffd5b506101fe6106c73660046123b5565b6110b8565b6106d46110e1565b5f5b828110156107175761070f858585848181106106f4576106f46126a9565b905060200201602081019061070991906126bd565b84611158565b6001016106d6565b5050505050565b6001600160401b0381165f9081526001602081905260408220015461075290600160801b90046001600160701b0316611216565b92915050565b6107606110e1565b61076a8282611234565b5050565b6107766110e1565b604051637a9e5e4b60e01b81526001600160a01b038281166004830152831690637a9e5e4b906024015f604051808303815f87803b1580156107b6575f5ffd5b505af11580156107c8573d5f5f3e3d5ffd5b505050505050565b5f3381806107e0838888886112a5565b91509150811580156107f6575063ffffffff8116155b1561084957828761080788886112f6565b6040516381c6f24b60e01b81526001600160a01b0393841660048201529290911660248301526001600160e01b03191660448201526064015b60405180910390fd5b5f61085684898989610bb8565b90505f63ffffffff831615158061087c575061087182610994565b65ffffffffffff1615155b1561088d5761088a8261130d565b90505b6003546108a38a61089e8b8b6112f6565b61140b565b6003819055506108ea8a8a8a8080601f0160208091040260200160405190810160405280939291908181526020018383808284375f92019190915250349250611430915050565b506003559450505050505b9392505050565b6109046110e1565b61091883836109128661071e565b846114fc565b50505050565b6001600160401b0382165f9081526001602090815260408083206001600160a01b03851684529091528120805465ffffffffffff81169291829182919061097490600160301b90046001600160701b0316611742565b969991985096509350505050565b61098a6110e1565b61076a8282611763565b5f8181526002602052604081205465ffffffffffff166109b381611806565b6109bd57806108f5565b5f9392505050565b6001600160a01b0381165f90815260208190526040812060010154610752906001600160701b0316611216565b6109fa6110e1565b61076a8282611834565b6001600160a01b0382165f908152602081815260408083206001600160e01b0319851684529091529020546001600160401b031692915050565b610a466110e1565b6001600160401b0383161580610a6457506001600160401b03838116145b15610a8d5760405163061c6a4360e21b81526001600160401b0384166004820152602401610840565b826001600160401b03167f1256f5b5ecb89caec12db449738f2fbcd1ba5806cf38f35413f4e5c15bf6a4508383604051610ac8929190612700565b60405180910390a2505050565b60408051638fb3603760e01b80825291513392918391638fb36037916004808201926020929091908290030181865afa158015610b14573d5f5f3e3d5ffd5b505050506040513d601f19601f82011682018060405250810190610b389190612713565b6001600160e01b03191614610b6b57604051630641fee960e31b81526001600160a01b0382166004820152602401610840565b610717610b7a85838686610bb8565b61130d565b6001600160a01b03165f90815260208190526040902060010154600160701b900460ff1690565b610bae6110e1565b61076a82826118e5565b5f84848484604051602001610bd0949392919061272e565b6040516020818303038152906040528051906020012090505b949350505050565b604080515f815260208101909152606090826001600160401b03811115610c1a57610c1a61279f565b604051908082528060200260200182016040528015610c4d57816020015b6060815260200190600190039081610c385790505b5091505f5b83811015610cce57610ca930868684818110610c7057610c706126a9565b9050602002810190610c8291906127b3565b85604051602001610c95939291906127f5565b6040516020818303038152906040526119f4565b838281518110610cbb57610cbb6126a9565b6020908102919091010152600101610c52565b505092915050565b5f5f610ce184610b7f565b15610cf057505f905080610dbf565b306001600160a01b03861603610d1457610d0a8484611a76565b5f91509150610dbf565b638561a1b560e01b6001600160e01b0319841601610d84575f5f610d385f88610dde565b915091505f610d46876109c5565b90505f610d5f8363ffffffff168363ffffffff16611a8c565b905083610d6d575f5f610d77565b63ffffffff811615815b9550955050505050610dbf565b5f610d8f8585610a04565b90505f5f610d9d8389610dde565b9150915081610dad575f5f610db7565b63ffffffff811615815b945094505050505b935093915050565b610dcf6110e1565b610dd98282611a9b565b505050565b5f8067fffffffffffffffe196001600160401b03851601610e045750600190505f610e50565b5f5f610e10868661091e565b5050915091508165ffffffffffff165f14158015610e455750610e31611b84565b65ffffffffffff168265ffffffffffff1611155b93509150610e509050565b9250929050565b610e5f6110e1565b61076a8282611b93565b5f3381610e7685856112f6565b90505f610e8588888888610bb8565b5f8181526002602052604081205491925065ffffffffffff9091169003610ec25760405163060a299b60e41b815260048101829052602401610840565b610ece88888888611c4e565b610f1657604051630ff89d4760e21b81526001600160a01b038085166004830152808a166024830152881660448201526001600160e01b031983166064820152608401610840565b5f81815260026020526040808220805465ffffffffffff1916908190559051600160301b90910463ffffffff1691829184917fbd9ac67a6e2f6463b80927326310338bcbb4bdb7936ce1365ea3e01067e7b9f791a398975050505050505050565b5f803381610f87828989896112a5565b9150505f8163ffffffff16610f9a611b84565b610fa49190612818565b905063ffffffff82161580610fda57505f8665ffffffffffff16118015610fda57508065ffffffffffff168665ffffffffffff16105b15610feb5782896108078a8a6112f6565b6110058665ffffffffffff168265ffffffffffff16611a8c565b9550611013838a8a8a610bb8565b945061101e85611d16565b5f8581526002602052604090819020805465ffffffffffff891669ffffffffffffffffffff19821617600160301b9182900463ffffffff90811660010190811692830291909117909255915190955086907f82a2da5dee54ea8021c6545b4444620291e07ee83be6dd57edb175062715f3b4906110a4908a9088908f908f908f90612836565b60405180910390a350505094509492505050565b6001600160a01b0381163314610dcf57604051635f159e6360e01b815260040160405180910390fd5b335f806110ef838236611d62565b9150915081610dd9578063ffffffff165f03611149575f6111108136611e25565b5060405163f07e038f60e01b81526001600160a01b03871660048201526001600160401b03821660248201529092506044019050610840565b610918610b7a84305f36610bb8565b638561a1b560e01b6001600160e01b031983160161119557604051637a3a272560e11b81526001600160e01b031983166004820152602401610840565b6001600160a01b0383165f818152602081815260408083206001600160e01b0319871680855290835292819020805467ffffffffffffffff19166001600160401b038716908117909155905192835292917f9ea6790c7dadfd01c9f8b9762b3682607af2c7e79e05a9f9fdf5580dde949151910160405180910390a3505050565b5f5f61122a836001600160701b0316611742565b5090949350505050565b6001600160a01b0382165f81815260208190526040908190206001018054841515600160701b0260ff60701b19909116179055517f90d4e7bb7e5d933792b3562e1741306f8be94837e1348dacef9b6f1df56eb1389061129990841515815260200190565b60405180910390a25050565b5f80306001600160a01b038616036112cb576112c2868585611d62565b915091506112ed565b600483106112e7576112e286866105c287876112f6565b6112c2565b505f9050805b94509492505050565b5f6113046004828486612778565b6108f59161287b565b5f8181526002602052604081205465ffffffffffff811690600160301b900463ffffffff168183036113555760405163060a299b60e41b815260048101859052602401610840565b61135d611b84565b65ffffffffffff168265ffffffffffff16111561139057604051630c65b5bd60e11b815260048101859052602401610840565b61139982611806565b156113ba57604051631e2975b960e21b815260048101859052602401610840565b5f84815260026020526040808220805465ffffffffffff191690555163ffffffff83169186917f76a2a46953689d4861a5d3f6ed883ad7e6af674a21f8e162707159fc9dde614d9190a39392505050565b6001600160a01b0382165f9081526001600160e01b03198216602052604081206108f5565b60608147101561145c5760405163cf47918160e01b815247600482015260248101839052604401610840565b5f61146885848661200b565b905080801561148957505f3d118061148957505f856001600160a01b03163b115b1561149e57611496612020565b9150506108f5565b80156114c857604051639996b31560e01b81526001600160a01b0386166004820152602401610840565b3d156114db576114d6612039565b6114f4565b60405163d6bda27560e01b815260040160405180910390fd5b509392505050565b5f67fffffffffffffffe196001600160401b0386160161153a5760405163061c6a4360e21b81526001600160401b0386166004820152602401610840565b6001600160401b0385165f9081526001602090815260408083206001600160a01b038816845290915281205465ffffffffffff161590811561162a578463ffffffff16611585611b84565b61158f9190612818565b905060405180604001604052808265ffffffffffff1681526020016115bd8663ffffffff1663ffffffff1690565b6001600160701b039081169091526001600160401b0389165f9081526001602090815260408083206001600160a01b038c1684528252909120835181549490920151909216600160301b026001600160a01b031990931665ffffffffffff909116179190911790556116d4565b6001600160401b0387165f9081526001602090815260408083206001600160a01b038a16845290915281205461167391600160301b9091046001600160701b0316908690612044565b6001600160401b0389165f9081526001602090815260408083206001600160a01b038c168452909152902080546001600160701b03909316600160301b0273ffffffffffffffffffffffffffff000000000000199093169290921790915590505b6040805163ffffffff8616815265ffffffffffff831660208201528315158183015290516001600160a01b038816916001600160401b038a16917ff98448b987f1428e0e230e1f3c6e2ce15b5693eaf31827fbd0b1ec4b424ae7cf9181900360600190a35095945050505050565b5f5f5f61175684611751611b84565b6120ea565b9250925092509193909250565b6001600160401b038216158061178157506001600160401b03828116145b156117aa5760405163061c6a4360e21b81526001600160401b0383166004820152602401610840565b6001600160401b038281165f818152600160208190526040808320909101805467ffffffffffffffff19169486169485179055517f1fd6dd7631312dfac2205b52913f99de03b4d7e381d5d27d3dbfe0713e6e63409190a35050565b5f61180f611b84565b65ffffffffffff1661182462093a8084612818565b65ffffffffffff16111592915050565b6001600160401b038216158061185257506001600160401b03828116145b1561187b5760405163061c6a4360e21b81526001600160401b0383166004820152602401610840565b6001600160401b038281165f81815260016020819052604080832090910180546fffffffffffffffff00000000000000001916600160401b958716958602179055517f7a8059630b897b5de4c08ade69f8b90c3ead1f8596d62d10b6c4d14a0afb4ae29190a35050565b67fffffffffffffffe196001600160401b038316016119225760405163061c6a4360e21b81526001600160401b0383166004820152602401610840565b6001600160401b0382165f9081526001602081905260408220015461195b90600160801b90046001600160701b03168362069780612044565b6001600160401b0385165f818152600160208190526040918290200180546001600160701b03909516600160801b026dffffffffffffffffffffffffffff60801b199095169490941790935591519092507ffeb69018ee8b8fd50ea86348f1267d07673379f72cffdeccec63853ee8ce8b4890610ac8908590859063ffffffff92909216825265ffffffffffff16602082015260400190565b60605f611a018484612136565b9050808015611a2257505f3d1180611a2257505f846001600160a01b03163b115b15611a3757611a2f612020565b915050610752565b8015611a6157604051639996b31560e01b81526001600160a01b0385166004820152602401610840565b3d156114db57611a6f612039565b5092915050565b5f611a81838361140b565b600354149392505050565b5f8282188284110282186108f5565b5f67fffffffffffffffe196001600160401b03841601611ad95760405163061c6a4360e21b81526001600160401b0384166004820152602401610840565b6001600160401b0383165f9081526001602090815260408083206001600160a01b038616845290915281205465ffffffffffff169003611b1a57505f610752565b6001600160401b0383165f8181526001602090815260408083206001600160a01b038716808552925280832080546001600160a01b0319169055519092917ff229baa593af28c41b1d16b748cd7688f0c83aaf92d4be41c44005defe84c16691a350600192915050565b5f611b8e42612149565b905090565b6001600160a01b0382165f90815260208190526040812060010154611bc5906001600160701b03168362069780612044565b6001600160a01b0385165f818152602081815260409182902060010180546dffffffffffffffffffffffffffff19166001600160701b039690961695909517909455805163ffffffff8716815265ffffffffffff841694810194909452919350917fa56b76017453f399ec2327ba00375dbfb1fd070ff854341ad6191e6a2e2de19c9101610ac8565b5f336001600160a01b038616819003611c6b576001915050610be9565b5f611c765f83610dde565b5090505f611c94611c8e61021a896104ab8a8a6112f6565b84610dde565b5090508180611ca05750805b15611cb15760019350505050610be9565b306001600160a01b03881603611d09575f5f611ccd8888611e25565b5091509150818015611ce757506001600160401b03811615155b15611d06575f611cf78287610dde565b509650610be995505050505050565b50505b505f979650505050505050565b5f8181526002602052604090205465ffffffffffff168015801590611d415750611d3f81611806565b155b1561076a5760405163813e945960e01b815260048101839052602401610840565b5f806004831015611d7757505f905080610dbf565b306001600160a01b03861603611d9a57610d0a30611d9586866112f6565b611a76565b5f5f5f611da78787611e25565b92509250925082158015611dbf5750611dbf30610b7f565b15611dd2575f5f94509450505050610dbf565b5f5f611dde848b610dde565b9150915081611df7575f5f965096505050505050610dbf565b611e0d8363ffffffff168263ffffffff16611a8c565b63ffffffff8116159b909a5098505050505050505050565b5f80806004841015611e3e57505f915081905080612004565b5f611e4986866112f6565b90506001600160e01b031981166310a6aa3760e31b1480611e7a57506001600160e01b031981166330cae18760e01b145b80611e9557506001600160e01b0319811663294b14a960e11b145b80611eb057506001600160e01b03198116635326cae760e11b145b80611ecb57506001600160e01b0319811663d22b598960e01b145b15611ee05760015f5f93509350935050612004565b6001600160e01b0319811663063fc60f60e21b1480611f0f57506001600160e01b0319811663167bd39560e01b145b80611f2a57506001600160e01b031981166308d6122d60e01b145b15611f69575f611f3e60246004888a612778565b810190611f4b9190612417565b90505f611f57826109c5565b600196505f9550935061200492505050565b6001600160e01b0319811663012e238d60e51b1480611f9857506001600160e01b03198116635be958b160e11b145b15611ff0575f611fac60246004888a612778565b810190611fb99190612253565b90506001611fe2826001600160401b039081165f90815260016020819052604090912001541690565b5f9450945094505050612004565b5f611ffb3083610a04565b5f935093509350505b9250925092565b5f5f5f83516020850186885af1949350505050565b6040513d81523d5f602083013e3d602001810160405290565b6040513d5f823e3d81fd5b5f5f5f612059866001600160701b0316611216565b90505f6120948563ffffffff168763ffffffff168463ffffffff161161207f575f612089565b61208988856128b1565b63ffffffff16611a8c565b90508063ffffffff166120a5611b84565b6120af9190612818565b925063ffffffff8616602083901b67ffffffff0000000016604085901b6dffffffffffff000000000000000016171793505050935093915050565b69ffffffffffffffffffff602083901c166001600160701b03831665ffffffffffff604085901c811690841681111561212557828282612129565b815f5f5b9250925092509250925092565b5f5f5f835160208501865af49392505050565b5f65ffffffffffff82111561217b576040516306dfcc6560e41b81526030600482015260248101839052604401610840565b5090565b6001600160a01b0381168114612193575f5ffd5b50565b5f5f83601f8401126121a6575f5ffd5b5081356001600160401b038111156121bc575f5ffd5b6020830191508360208260051b8501011115610e50575f5ffd5b80356001600160401b03811681146121ec575f5ffd5b919050565b5f5f5f5f60608587031215612204575f5ffd5b843561220f8161217f565b935060208501356001600160401b03811115612229575f5ffd5b61223587828801612196565b90945092506122489050604086016121d6565b905092959194509250565b5f60208284031215612263575f5ffd5b6108f5826121d6565b5f5f6040838503121561227d575f5ffd5b82356122888161217f565b91506020830135801515811461229c575f5ffd5b809150509250929050565b5f5f604083850312156122b8575f5ffd5b82356122c38161217f565b9150602083013561229c8161217f565b5f5f83601f8401126122e3575f5ffd5b5081356001600160401b038111156122f9575f5ffd5b602083019150836020828501011115610e50575f5ffd5b5f5f5f60408486031215612322575f5ffd5b833561232d8161217f565b925060208401356001600160401b03811115612347575f5ffd5b612353868287016122d3565b9497909650939450505050565b803563ffffffff811681146121ec575f5ffd5b5f5f5f60608486031215612385575f5ffd5b61238e846121d6565b9250602084013561239e8161217f565b91506123ac60408501612360565b90509250925092565b5f5f604083850312156123c6575f5ffd5b6122c3836121d6565b5f5f604083850312156123e0575f5ffd5b6123e9836121d6565b91506123f7602084016121d6565b90509250929050565b5f60208284031215612410575f5ffd5b5035919050565b5f60208284031215612427575f5ffd5b81356108f58161217f565b6001600160e01b031981168114612193575f5ffd5b5f5f60408385031215612458575f5ffd5b82356124638161217f565b9150602083013561229c81612432565b5f5f5f60408486031215612485575f5ffd5b61232d846121d6565b5f5f6040838503121561249f575f5ffd5b6124a8836121d6565b91506123f760208401612360565b5f5f5f5f606085870312156124c9575f5ffd5b84356124d48161217f565b935060208501356124e48161217f565b925060408501356001600160401b038111156124fe575f5ffd5b61250a878288016122d3565b95989497509550505050565b5f5f60208385031215612527575f5ffd5b82356001600160401b0381111561253c575f5ffd5b61254885828601612196565b90969095509350505050565b5f602082016020835280845180835260408501915060408160051b8601019250602086015f5b828110156125cc57603f19878603018452815180518087528060208301602089015e5f602082890101526020601f19601f8301168801019650505060208201915060208401935060018101905061257a565b50929695505050505050565b5f5f5f606084860312156125ea575f5ffd5b83356125f58161217f565b925060208401356126058161217f565b9150604084013561261581612432565b809150509250925092565b5f5f60408385031215612631575f5ffd5b82356124a88161217f565b5f5f5f5f6060858703121561264f575f5ffd5b843561265a8161217f565b935060208501356001600160401b03811115612674575f5ffd5b612680878288016122d3565b909450925050604085013565ffffffffffff8116811461269e575f5ffd5b939692955090935050565b634e487b7160e01b5f52603260045260245ffd5b5f602082840312156126cd575f5ffd5b81356108f581612432565b81835281816020850137505f828201602090810191909152601f909101601f19169091010190565b602081525f610be96020830184866126d8565b5f60208284031215612723575f5ffd5b81516108f581612432565b6001600160a01b038581168252841660208201526060604082018190525f9061275a90830184866126d8565b9695505050505050565b634e487b7160e01b5f52601160045260245ffd5b5f5f85851115612786575f5ffd5b83861115612792575f5ffd5b5050820193919092039150565b634e487b7160e01b5f52604160045260245ffd5b5f5f8335601e198436030181126127c8575f5ffd5b8301803591506001600160401b038211156127e1575f5ffd5b602001915036819003821315610e50575f5ffd5b828482375f8382015f815283518060208601835e5f910190815295945050505050565b65ffffffffffff818116838216019081111561075257610752612764565b65ffffffffffff861681526001600160a01b038581166020830152841660408201526080606082018190525f9061287090830184866126d8565b979650505050505050565b80356001600160e01b03198116906004841015611a6f576001600160e01b031960049490940360031b84901b1690921692915050565b63ffffffff82811682821603908111156107525761075261276456",
}

// AccessManagerABI is the input ABI used to generate the binding from.
// Deprecated: Use AccessManagerMetaData.ABI instead.
var AccessManagerABI = AccessManagerMetaData.ABI

// AccessManagerBin is the compiled bytecode used for deploying new contracts.
// Deprecated: Use AccessManagerMetaData.Bin instead.
var AccessManagerBin = AccessManagerMetaData.Bin

// DeployAccessManager deploys a new Ethereum contract, binding an instance of AccessManager to it.
func DeployAccessManager(auth *bind.TransactOpts, backend bind.ContractBackend, initialAdmin common.Address) (common.Address, *types.Transaction, *AccessManager, error) {
	parsed, err := AccessManagerMetaData.GetAbi()
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	if parsed == nil {
		return common.Address{}, nil, nil, errors.New("GetABI returned nil")
	}

	address, tx, contract, err := bind.DeployContract(auth, *parsed, common.FromHex(AccessManagerBin), backend, initialAdmin)
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	return address, tx, &AccessManager{AccessManagerCaller: AccessManagerCaller{contract: contract}, AccessManagerTransactor: AccessManagerTransactor{contract: contract}, AccessManagerFilterer: AccessManagerFilterer{contract: contract}}, nil
}

// AccessManager is an auto generated Go binding around an Ethereum contract.
type AccessManager struct {
	AccessManagerCaller     // Read-only binding to the contract
	AccessManagerTransactor // Write-only binding to the contract
	AccessManagerFilterer   // Log filterer for contract events
}

// AccessManagerCaller is an auto generated read-only Go binding around an Ethereum contract.
type AccessManagerCaller struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// AccessManagerTransactor is an auto generated write-only Go binding around an Ethereum contract.
type AccessManagerTransactor struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// AccessManagerFilterer is an auto generated log filtering Go binding around an Ethereum contract events.
type AccessManagerFilterer struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// AccessManagerSession is an auto generated Go binding around an Ethereum contract,
// with pre-set call and transact options.
type AccessManagerSession struct {
	Contract     *AccessManager    // Generic contract binding to set the session for
	CallOpts     bind.CallOpts     // Call options to use throughout this session
	TransactOpts bind.TransactOpts // Transaction auth options to use throughout this session
}

// AccessManagerCallerSession is an auto generated read-only Go binding around an Ethereum contract,
// with pre-set call options.
type AccessManagerCallerSession struct {
	Contract *AccessManagerCaller // Generic contract caller binding to set the session for
	CallOpts bind.CallOpts        // Call options to use throughout this session
}

// AccessManagerTransactorSession is an auto generated write-only Go binding around an Ethereum contract,
// with pre-set transact options.
type AccessManagerTransactorSession struct {
	Contract     *AccessManagerTransactor // Generic contract transactor binding to set the session for
	TransactOpts bind.TransactOpts        // Transaction auth options to use throughout this session
}

// AccessManagerRaw is an auto generated low-level Go binding around an Ethereum contract.
type AccessManagerRaw struct {
	Contract *AccessManager // Generic contract binding to access the raw methods on
}

// AccessManagerCallerRaw is an auto generated low-level read-only Go binding around an Ethereum contract.
type AccessManagerCallerRaw struct {
	Contract *AccessManagerCaller // Generic read-only contract binding to access the raw methods on
}

// AccessManagerTransactorRaw is an auto generated low-level write-only Go binding around an Ethereum contract.
type AccessManagerTransactorRaw struct {
	Contract *AccessManagerTransactor // Generic write-only contract binding to access the raw methods on
}

// NewAccessManager creates a new instance of AccessManager, bound to a specific deployed contract.
func NewAccessManager(address common.Address, backend bind.ContractBackend) (*AccessManager, error) {
	contract, err := bindAccessManager(address, backend, backend, backend)
	if err != nil {
		return nil, err
	}
	return &AccessManager{AccessManagerCaller: AccessManagerCaller{contract: contract}, AccessManagerTransactor: AccessManagerTransactor{contract: contract}, AccessManagerFilterer: AccessManagerFilterer{contract: contract}}, nil
}

// NewAccessManagerCaller creates a new read-only instance of AccessManager, bound to a specific deployed contract.
func NewAccessManagerCaller(address common.Address, caller bind.ContractCaller) (*AccessManagerCaller, error) {
	contract, err := bindAccessManager(address, caller, nil, nil)
	if err != nil {
		return nil, err
	}
	return &AccessManagerCaller{contract: contract}, nil
}

// NewAccessManagerTransactor creates a new write-only instance of AccessManager, bound to a specific deployed contract.
func NewAccessManagerTransactor(address common.Address, transactor bind.ContractTransactor) (*AccessManagerTransactor, error) {
	contract, err := bindAccessManager(address, nil, transactor, nil)
	if err != nil {
		return nil, err
	}
	return &AccessManagerTransactor{contract: contract}, nil
}

// NewAccessManagerFilterer creates a new log filterer instance of AccessManager, bound to a specific deployed contract.
func NewAccessManagerFilterer(address common.Address, filterer bind.ContractFilterer) (*AccessManagerFilterer, error) {
	contract, err := bindAccessManager(address, nil, nil, filterer)
	if err != nil {
		return nil, err
	}
	return &AccessManagerFilterer{contract: contract}, nil
}

// bindAccessManager binds a generic wrapper to an already deployed contract.
func bindAccessManager(address common.Address, caller bind.ContractCaller, transactor bind.ContractTransactor, filterer bind.ContractFilterer) (*bind.BoundContract, error) {
	parsed, err := AccessManagerMetaData.GetAbi()
	if err != nil {
		return nil, err
	}
	return bind.NewBoundContract(address, *parsed, caller, transactor, filterer), nil
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_AccessManager *AccessManagerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _AccessManager.Contract.AccessManagerCaller.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_AccessManager *AccessManagerRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _AccessManager.Contract.AccessManagerTransactor.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_AccessManager *AccessManagerRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _AccessManager.Contract.AccessManagerTransactor.contract.Transact(opts, method, params...)
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_AccessManager *AccessManagerCallerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _AccessManager.Contract.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_AccessManager *AccessManagerTransactorRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _AccessManager.Contract.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_AccessManager *AccessManagerTransactorRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _AccessManager.Contract.contract.Transact(opts, method, params...)
}

// ADMINROLE is a free data retrieval call binding the contract method 0x75b238fc.
//
// Solidity: function ADMIN_ROLE() view returns(uint64)
func (_AccessManager *AccessManagerCaller) ADMINROLE(opts *bind.CallOpts) (uint64, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "ADMIN_ROLE")

	if err != nil {
		return *new(uint64), err
	}

	out0 := *abi.ConvertType(out[0], new(uint64)).(*uint64)

	return out0, err

}

// ADMINROLE is a free data retrieval call binding the contract method 0x75b238fc.
//
// Solidity: function ADMIN_ROLE() view returns(uint64)
func (_AccessManager *AccessManagerSession) ADMINROLE() (uint64, error) {
	return _AccessManager.Contract.ADMINROLE(&_AccessManager.CallOpts)
}

// ADMINROLE is a free data retrieval call binding the contract method 0x75b238fc.
//
// Solidity: function ADMIN_ROLE() view returns(uint64)
func (_AccessManager *AccessManagerCallerSession) ADMINROLE() (uint64, error) {
	return _AccessManager.Contract.ADMINROLE(&_AccessManager.CallOpts)
}

// PUBLICROLE is a free data retrieval call binding the contract method 0x3ca7c02a.
//
// Solidity: function PUBLIC_ROLE() view returns(uint64)
func (_AccessManager *AccessManagerCaller) PUBLICROLE(opts *bind.CallOpts) (uint64, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "PUBLIC_ROLE")

	if err != nil {
		return *new(uint64), err
	}

	out0 := *abi.ConvertType(out[0], new(uint64)).(*uint64)

	return out0, err

}

// PUBLICROLE is a free data retrieval call binding the contract method 0x3ca7c02a.
//
// Solidity: function PUBLIC_ROLE() view returns(uint64)
func (_AccessManager *AccessManagerSession) PUBLICROLE() (uint64, error) {
	return _AccessManager.Contract.PUBLICROLE(&_AccessManager.CallOpts)
}

// PUBLICROLE is a free data retrieval call binding the contract method 0x3ca7c02a.
//
// Solidity: function PUBLIC_ROLE() view returns(uint64)
func (_AccessManager *AccessManagerCallerSession) PUBLICROLE() (uint64, error) {
	return _AccessManager.Contract.PUBLICROLE(&_AccessManager.CallOpts)
}

// CanCall is a free data retrieval call binding the contract method 0xb7009613.
//
// Solidity: function canCall(address caller, address target, bytes4 selector) view returns(bool immediate, uint32 delay)
func (_AccessManager *AccessManagerCaller) CanCall(opts *bind.CallOpts, caller common.Address, target common.Address, selector [4]byte) (struct {
	Immediate bool
	Delay     uint32
}, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "canCall", caller, target, selector)

	outstruct := new(struct {
		Immediate bool
		Delay     uint32
	})
	if err != nil {
		return *outstruct, err
	}

	outstruct.Immediate = *abi.ConvertType(out[0], new(bool)).(*bool)
	outstruct.Delay = *abi.ConvertType(out[1], new(uint32)).(*uint32)

	return *outstruct, err

}

// CanCall is a free data retrieval call binding the contract method 0xb7009613.
//
// Solidity: function canCall(address caller, address target, bytes4 selector) view returns(bool immediate, uint32 delay)
func (_AccessManager *AccessManagerSession) CanCall(caller common.Address, target common.Address, selector [4]byte) (struct {
	Immediate bool
	Delay     uint32
}, error) {
	return _AccessManager.Contract.CanCall(&_AccessManager.CallOpts, caller, target, selector)
}

// CanCall is a free data retrieval call binding the contract method 0xb7009613.
//
// Solidity: function canCall(address caller, address target, bytes4 selector) view returns(bool immediate, uint32 delay)
func (_AccessManager *AccessManagerCallerSession) CanCall(caller common.Address, target common.Address, selector [4]byte) (struct {
	Immediate bool
	Delay     uint32
}, error) {
	return _AccessManager.Contract.CanCall(&_AccessManager.CallOpts, caller, target, selector)
}

// Expiration is a free data retrieval call binding the contract method 0x4665096d.
//
// Solidity: function expiration() view returns(uint32)
func (_AccessManager *AccessManagerCaller) Expiration(opts *bind.CallOpts) (uint32, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "expiration")

	if err != nil {
		return *new(uint32), err
	}

	out0 := *abi.ConvertType(out[0], new(uint32)).(*uint32)

	return out0, err

}

// Expiration is a free data retrieval call binding the contract method 0x4665096d.
//
// Solidity: function expiration() view returns(uint32)
func (_AccessManager *AccessManagerSession) Expiration() (uint32, error) {
	return _AccessManager.Contract.Expiration(&_AccessManager.CallOpts)
}

// Expiration is a free data retrieval call binding the contract method 0x4665096d.
//
// Solidity: function expiration() view returns(uint32)
func (_AccessManager *AccessManagerCallerSession) Expiration() (uint32, error) {
	return _AccessManager.Contract.Expiration(&_AccessManager.CallOpts)
}

// GetAccess is a free data retrieval call binding the contract method 0x3078f114.
//
// Solidity: function getAccess(uint64 roleId, address account) view returns(uint48 since, uint32 currentDelay, uint32 pendingDelay, uint48 effect)
func (_AccessManager *AccessManagerCaller) GetAccess(opts *bind.CallOpts, roleId uint64, account common.Address) (struct {
	Since        *big.Int
	CurrentDelay uint32
	PendingDelay uint32
	Effect       *big.Int
}, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "getAccess", roleId, account)

	outstruct := new(struct {
		Since        *big.Int
		CurrentDelay uint32
		PendingDelay uint32
		Effect       *big.Int
	})
	if err != nil {
		return *outstruct, err
	}

	outstruct.Since = *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)
	outstruct.CurrentDelay = *abi.ConvertType(out[1], new(uint32)).(*uint32)
	outstruct.PendingDelay = *abi.ConvertType(out[2], new(uint32)).(*uint32)
	outstruct.Effect = *abi.ConvertType(out[3], new(*big.Int)).(**big.Int)

	return *outstruct, err

}

// GetAccess is a free data retrieval call binding the contract method 0x3078f114.
//
// Solidity: function getAccess(uint64 roleId, address account) view returns(uint48 since, uint32 currentDelay, uint32 pendingDelay, uint48 effect)
func (_AccessManager *AccessManagerSession) GetAccess(roleId uint64, account common.Address) (struct {
	Since        *big.Int
	CurrentDelay uint32
	PendingDelay uint32
	Effect       *big.Int
}, error) {
	return _AccessManager.Contract.GetAccess(&_AccessManager.CallOpts, roleId, account)
}

// GetAccess is a free data retrieval call binding the contract method 0x3078f114.
//
// Solidity: function getAccess(uint64 roleId, address account) view returns(uint48 since, uint32 currentDelay, uint32 pendingDelay, uint48 effect)
func (_AccessManager *AccessManagerCallerSession) GetAccess(roleId uint64, account common.Address) (struct {
	Since        *big.Int
	CurrentDelay uint32
	PendingDelay uint32
	Effect       *big.Int
}, error) {
	return _AccessManager.Contract.GetAccess(&_AccessManager.CallOpts, roleId, account)
}

// GetNonce is a free data retrieval call binding the contract method 0x4136a33c.
//
// Solidity: function getNonce(bytes32 id) view returns(uint32)
func (_AccessManager *AccessManagerCaller) GetNonce(opts *bind.CallOpts, id [32]byte) (uint32, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "getNonce", id)

	if err != nil {
		return *new(uint32), err
	}

	out0 := *abi.ConvertType(out[0], new(uint32)).(*uint32)

	return out0, err

}

// GetNonce is a free data retrieval call binding the contract method 0x4136a33c.
//
// Solidity: function getNonce(bytes32 id) view returns(uint32)
func (_AccessManager *AccessManagerSession) GetNonce(id [32]byte) (uint32, error) {
	return _AccessManager.Contract.GetNonce(&_AccessManager.CallOpts, id)
}

// GetNonce is a free data retrieval call binding the contract method 0x4136a33c.
//
// Solidity: function getNonce(bytes32 id) view returns(uint32)
func (_AccessManager *AccessManagerCallerSession) GetNonce(id [32]byte) (uint32, error) {
	return _AccessManager.Contract.GetNonce(&_AccessManager.CallOpts, id)
}

// GetRoleAdmin is a free data retrieval call binding the contract method 0x530dd456.
//
// Solidity: function getRoleAdmin(uint64 roleId) view returns(uint64)
func (_AccessManager *AccessManagerCaller) GetRoleAdmin(opts *bind.CallOpts, roleId uint64) (uint64, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "getRoleAdmin", roleId)

	if err != nil {
		return *new(uint64), err
	}

	out0 := *abi.ConvertType(out[0], new(uint64)).(*uint64)

	return out0, err

}

// GetRoleAdmin is a free data retrieval call binding the contract method 0x530dd456.
//
// Solidity: function getRoleAdmin(uint64 roleId) view returns(uint64)
func (_AccessManager *AccessManagerSession) GetRoleAdmin(roleId uint64) (uint64, error) {
	return _AccessManager.Contract.GetRoleAdmin(&_AccessManager.CallOpts, roleId)
}

// GetRoleAdmin is a free data retrieval call binding the contract method 0x530dd456.
//
// Solidity: function getRoleAdmin(uint64 roleId) view returns(uint64)
func (_AccessManager *AccessManagerCallerSession) GetRoleAdmin(roleId uint64) (uint64, error) {
	return _AccessManager.Contract.GetRoleAdmin(&_AccessManager.CallOpts, roleId)
}

// GetRoleGrantDelay is a free data retrieval call binding the contract method 0x12be8727.
//
// Solidity: function getRoleGrantDelay(uint64 roleId) view returns(uint32)
func (_AccessManager *AccessManagerCaller) GetRoleGrantDelay(opts *bind.CallOpts, roleId uint64) (uint32, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "getRoleGrantDelay", roleId)

	if err != nil {
		return *new(uint32), err
	}

	out0 := *abi.ConvertType(out[0], new(uint32)).(*uint32)

	return out0, err

}

// GetRoleGrantDelay is a free data retrieval call binding the contract method 0x12be8727.
//
// Solidity: function getRoleGrantDelay(uint64 roleId) view returns(uint32)
func (_AccessManager *AccessManagerSession) GetRoleGrantDelay(roleId uint64) (uint32, error) {
	return _AccessManager.Contract.GetRoleGrantDelay(&_AccessManager.CallOpts, roleId)
}

// GetRoleGrantDelay is a free data retrieval call binding the contract method 0x12be8727.
//
// Solidity: function getRoleGrantDelay(uint64 roleId) view returns(uint32)
func (_AccessManager *AccessManagerCallerSession) GetRoleGrantDelay(roleId uint64) (uint32, error) {
	return _AccessManager.Contract.GetRoleGrantDelay(&_AccessManager.CallOpts, roleId)
}

// GetRoleGuardian is a free data retrieval call binding the contract method 0x0b0a93ba.
//
// Solidity: function getRoleGuardian(uint64 roleId) view returns(uint64)
func (_AccessManager *AccessManagerCaller) GetRoleGuardian(opts *bind.CallOpts, roleId uint64) (uint64, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "getRoleGuardian", roleId)

	if err != nil {
		return *new(uint64), err
	}

	out0 := *abi.ConvertType(out[0], new(uint64)).(*uint64)

	return out0, err

}

// GetRoleGuardian is a free data retrieval call binding the contract method 0x0b0a93ba.
//
// Solidity: function getRoleGuardian(uint64 roleId) view returns(uint64)
func (_AccessManager *AccessManagerSession) GetRoleGuardian(roleId uint64) (uint64, error) {
	return _AccessManager.Contract.GetRoleGuardian(&_AccessManager.CallOpts, roleId)
}

// GetRoleGuardian is a free data retrieval call binding the contract method 0x0b0a93ba.
//
// Solidity: function getRoleGuardian(uint64 roleId) view returns(uint64)
func (_AccessManager *AccessManagerCallerSession) GetRoleGuardian(roleId uint64) (uint64, error) {
	return _AccessManager.Contract.GetRoleGuardian(&_AccessManager.CallOpts, roleId)
}

// GetSchedule is a free data retrieval call binding the contract method 0x3adc277a.
//
// Solidity: function getSchedule(bytes32 id) view returns(uint48)
func (_AccessManager *AccessManagerCaller) GetSchedule(opts *bind.CallOpts, id [32]byte) (*big.Int, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "getSchedule", id)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// GetSchedule is a free data retrieval call binding the contract method 0x3adc277a.
//
// Solidity: function getSchedule(bytes32 id) view returns(uint48)
func (_AccessManager *AccessManagerSession) GetSchedule(id [32]byte) (*big.Int, error) {
	return _AccessManager.Contract.GetSchedule(&_AccessManager.CallOpts, id)
}

// GetSchedule is a free data retrieval call binding the contract method 0x3adc277a.
//
// Solidity: function getSchedule(bytes32 id) view returns(uint48)
func (_AccessManager *AccessManagerCallerSession) GetSchedule(id [32]byte) (*big.Int, error) {
	return _AccessManager.Contract.GetSchedule(&_AccessManager.CallOpts, id)
}

// GetTargetAdminDelay is a free data retrieval call binding the contract method 0x4c1da1e2.
//
// Solidity: function getTargetAdminDelay(address target) view returns(uint32)
func (_AccessManager *AccessManagerCaller) GetTargetAdminDelay(opts *bind.CallOpts, target common.Address) (uint32, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "getTargetAdminDelay", target)

	if err != nil {
		return *new(uint32), err
	}

	out0 := *abi.ConvertType(out[0], new(uint32)).(*uint32)

	return out0, err

}

// GetTargetAdminDelay is a free data retrieval call binding the contract method 0x4c1da1e2.
//
// Solidity: function getTargetAdminDelay(address target) view returns(uint32)
func (_AccessManager *AccessManagerSession) GetTargetAdminDelay(target common.Address) (uint32, error) {
	return _AccessManager.Contract.GetTargetAdminDelay(&_AccessManager.CallOpts, target)
}

// GetTargetAdminDelay is a free data retrieval call binding the contract method 0x4c1da1e2.
//
// Solidity: function getTargetAdminDelay(address target) view returns(uint32)
func (_AccessManager *AccessManagerCallerSession) GetTargetAdminDelay(target common.Address) (uint32, error) {
	return _AccessManager.Contract.GetTargetAdminDelay(&_AccessManager.CallOpts, target)
}

// GetTargetFunctionRole is a free data retrieval call binding the contract method 0x6d5115bd.
//
// Solidity: function getTargetFunctionRole(address target, bytes4 selector) view returns(uint64)
func (_AccessManager *AccessManagerCaller) GetTargetFunctionRole(opts *bind.CallOpts, target common.Address, selector [4]byte) (uint64, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "getTargetFunctionRole", target, selector)

	if err != nil {
		return *new(uint64), err
	}

	out0 := *abi.ConvertType(out[0], new(uint64)).(*uint64)

	return out0, err

}

// GetTargetFunctionRole is a free data retrieval call binding the contract method 0x6d5115bd.
//
// Solidity: function getTargetFunctionRole(address target, bytes4 selector) view returns(uint64)
func (_AccessManager *AccessManagerSession) GetTargetFunctionRole(target common.Address, selector [4]byte) (uint64, error) {
	return _AccessManager.Contract.GetTargetFunctionRole(&_AccessManager.CallOpts, target, selector)
}

// GetTargetFunctionRole is a free data retrieval call binding the contract method 0x6d5115bd.
//
// Solidity: function getTargetFunctionRole(address target, bytes4 selector) view returns(uint64)
func (_AccessManager *AccessManagerCallerSession) GetTargetFunctionRole(target common.Address, selector [4]byte) (uint64, error) {
	return _AccessManager.Contract.GetTargetFunctionRole(&_AccessManager.CallOpts, target, selector)
}

// HasRole is a free data retrieval call binding the contract method 0xd1f856ee.
//
// Solidity: function hasRole(uint64 roleId, address account) view returns(bool isMember, uint32 executionDelay)
func (_AccessManager *AccessManagerCaller) HasRole(opts *bind.CallOpts, roleId uint64, account common.Address) (struct {
	IsMember       bool
	ExecutionDelay uint32
}, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "hasRole", roleId, account)

	outstruct := new(struct {
		IsMember       bool
		ExecutionDelay uint32
	})
	if err != nil {
		return *outstruct, err
	}

	outstruct.IsMember = *abi.ConvertType(out[0], new(bool)).(*bool)
	outstruct.ExecutionDelay = *abi.ConvertType(out[1], new(uint32)).(*uint32)

	return *outstruct, err

}

// HasRole is a free data retrieval call binding the contract method 0xd1f856ee.
//
// Solidity: function hasRole(uint64 roleId, address account) view returns(bool isMember, uint32 executionDelay)
func (_AccessManager *AccessManagerSession) HasRole(roleId uint64, account common.Address) (struct {
	IsMember       bool
	ExecutionDelay uint32
}, error) {
	return _AccessManager.Contract.HasRole(&_AccessManager.CallOpts, roleId, account)
}

// HasRole is a free data retrieval call binding the contract method 0xd1f856ee.
//
// Solidity: function hasRole(uint64 roleId, address account) view returns(bool isMember, uint32 executionDelay)
func (_AccessManager *AccessManagerCallerSession) HasRole(roleId uint64, account common.Address) (struct {
	IsMember       bool
	ExecutionDelay uint32
}, error) {
	return _AccessManager.Contract.HasRole(&_AccessManager.CallOpts, roleId, account)
}

// HashOperation is a free data retrieval call binding the contract method 0xabd9bd2a.
//
// Solidity: function hashOperation(address caller, address target, bytes data) view returns(bytes32)
func (_AccessManager *AccessManagerCaller) HashOperation(opts *bind.CallOpts, caller common.Address, target common.Address, data []byte) ([32]byte, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "hashOperation", caller, target, data)

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// HashOperation is a free data retrieval call binding the contract method 0xabd9bd2a.
//
// Solidity: function hashOperation(address caller, address target, bytes data) view returns(bytes32)
func (_AccessManager *AccessManagerSession) HashOperation(caller common.Address, target common.Address, data []byte) ([32]byte, error) {
	return _AccessManager.Contract.HashOperation(&_AccessManager.CallOpts, caller, target, data)
}

// HashOperation is a free data retrieval call binding the contract method 0xabd9bd2a.
//
// Solidity: function hashOperation(address caller, address target, bytes data) view returns(bytes32)
func (_AccessManager *AccessManagerCallerSession) HashOperation(caller common.Address, target common.Address, data []byte) ([32]byte, error) {
	return _AccessManager.Contract.HashOperation(&_AccessManager.CallOpts, caller, target, data)
}

// IsTargetClosed is a free data retrieval call binding the contract method 0xa166aa89.
//
// Solidity: function isTargetClosed(address target) view returns(bool)
func (_AccessManager *AccessManagerCaller) IsTargetClosed(opts *bind.CallOpts, target common.Address) (bool, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "isTargetClosed", target)

	if err != nil {
		return *new(bool), err
	}

	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)

	return out0, err

}

// IsTargetClosed is a free data retrieval call binding the contract method 0xa166aa89.
//
// Solidity: function isTargetClosed(address target) view returns(bool)
func (_AccessManager *AccessManagerSession) IsTargetClosed(target common.Address) (bool, error) {
	return _AccessManager.Contract.IsTargetClosed(&_AccessManager.CallOpts, target)
}

// IsTargetClosed is a free data retrieval call binding the contract method 0xa166aa89.
//
// Solidity: function isTargetClosed(address target) view returns(bool)
func (_AccessManager *AccessManagerCallerSession) IsTargetClosed(target common.Address) (bool, error) {
	return _AccessManager.Contract.IsTargetClosed(&_AccessManager.CallOpts, target)
}

// MinSetback is a free data retrieval call binding the contract method 0xcc1b6c81.
//
// Solidity: function minSetback() view returns(uint32)
func (_AccessManager *AccessManagerCaller) MinSetback(opts *bind.CallOpts) (uint32, error) {
	var out []interface{}
	err := _AccessManager.contract.Call(opts, &out, "minSetback")

	if err != nil {
		return *new(uint32), err
	}

	out0 := *abi.ConvertType(out[0], new(uint32)).(*uint32)

	return out0, err

}

// MinSetback is a free data retrieval call binding the contract method 0xcc1b6c81.
//
// Solidity: function minSetback() view returns(uint32)
func (_AccessManager *AccessManagerSession) MinSetback() (uint32, error) {
	return _AccessManager.Contract.MinSetback(&_AccessManager.CallOpts)
}

// MinSetback is a free data retrieval call binding the contract method 0xcc1b6c81.
//
// Solidity: function minSetback() view returns(uint32)
func (_AccessManager *AccessManagerCallerSession) MinSetback() (uint32, error) {
	return _AccessManager.Contract.MinSetback(&_AccessManager.CallOpts)
}

// Cancel is a paid mutator transaction binding the contract method 0xd6bb62c6.
//
// Solidity: function cancel(address caller, address target, bytes data) returns(uint32)
func (_AccessManager *AccessManagerTransactor) Cancel(opts *bind.TransactOpts, caller common.Address, target common.Address, data []byte) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "cancel", caller, target, data)
}

// Cancel is a paid mutator transaction binding the contract method 0xd6bb62c6.
//
// Solidity: function cancel(address caller, address target, bytes data) returns(uint32)
func (_AccessManager *AccessManagerSession) Cancel(caller common.Address, target common.Address, data []byte) (*types.Transaction, error) {
	return _AccessManager.Contract.Cancel(&_AccessManager.TransactOpts, caller, target, data)
}

// Cancel is a paid mutator transaction binding the contract method 0xd6bb62c6.
//
// Solidity: function cancel(address caller, address target, bytes data) returns(uint32)
func (_AccessManager *AccessManagerTransactorSession) Cancel(caller common.Address, target common.Address, data []byte) (*types.Transaction, error) {
	return _AccessManager.Contract.Cancel(&_AccessManager.TransactOpts, caller, target, data)
}

// ConsumeScheduledOp is a paid mutator transaction binding the contract method 0x94c7d7ee.
//
// Solidity: function consumeScheduledOp(address caller, bytes data) returns()
func (_AccessManager *AccessManagerTransactor) ConsumeScheduledOp(opts *bind.TransactOpts, caller common.Address, data []byte) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "consumeScheduledOp", caller, data)
}

// ConsumeScheduledOp is a paid mutator transaction binding the contract method 0x94c7d7ee.
//
// Solidity: function consumeScheduledOp(address caller, bytes data) returns()
func (_AccessManager *AccessManagerSession) ConsumeScheduledOp(caller common.Address, data []byte) (*types.Transaction, error) {
	return _AccessManager.Contract.ConsumeScheduledOp(&_AccessManager.TransactOpts, caller, data)
}

// ConsumeScheduledOp is a paid mutator transaction binding the contract method 0x94c7d7ee.
//
// Solidity: function consumeScheduledOp(address caller, bytes data) returns()
func (_AccessManager *AccessManagerTransactorSession) ConsumeScheduledOp(caller common.Address, data []byte) (*types.Transaction, error) {
	return _AccessManager.Contract.ConsumeScheduledOp(&_AccessManager.TransactOpts, caller, data)
}

// Execute is a paid mutator transaction binding the contract method 0x1cff79cd.
//
// Solidity: function execute(address target, bytes data) payable returns(uint32)
func (_AccessManager *AccessManagerTransactor) Execute(opts *bind.TransactOpts, target common.Address, data []byte) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "execute", target, data)
}

// Execute is a paid mutator transaction binding the contract method 0x1cff79cd.
//
// Solidity: function execute(address target, bytes data) payable returns(uint32)
func (_AccessManager *AccessManagerSession) Execute(target common.Address, data []byte) (*types.Transaction, error) {
	return _AccessManager.Contract.Execute(&_AccessManager.TransactOpts, target, data)
}

// Execute is a paid mutator transaction binding the contract method 0x1cff79cd.
//
// Solidity: function execute(address target, bytes data) payable returns(uint32)
func (_AccessManager *AccessManagerTransactorSession) Execute(target common.Address, data []byte) (*types.Transaction, error) {
	return _AccessManager.Contract.Execute(&_AccessManager.TransactOpts, target, data)
}

// GrantRole is a paid mutator transaction binding the contract method 0x25c471a0.
//
// Solidity: function grantRole(uint64 roleId, address account, uint32 executionDelay) returns()
func (_AccessManager *AccessManagerTransactor) GrantRole(opts *bind.TransactOpts, roleId uint64, account common.Address, executionDelay uint32) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "grantRole", roleId, account, executionDelay)
}

// GrantRole is a paid mutator transaction binding the contract method 0x25c471a0.
//
// Solidity: function grantRole(uint64 roleId, address account, uint32 executionDelay) returns()
func (_AccessManager *AccessManagerSession) GrantRole(roleId uint64, account common.Address, executionDelay uint32) (*types.Transaction, error) {
	return _AccessManager.Contract.GrantRole(&_AccessManager.TransactOpts, roleId, account, executionDelay)
}

// GrantRole is a paid mutator transaction binding the contract method 0x25c471a0.
//
// Solidity: function grantRole(uint64 roleId, address account, uint32 executionDelay) returns()
func (_AccessManager *AccessManagerTransactorSession) GrantRole(roleId uint64, account common.Address, executionDelay uint32) (*types.Transaction, error) {
	return _AccessManager.Contract.GrantRole(&_AccessManager.TransactOpts, roleId, account, executionDelay)
}

// LabelRole is a paid mutator transaction binding the contract method 0x853551b8.
//
// Solidity: function labelRole(uint64 roleId, string label) returns()
func (_AccessManager *AccessManagerTransactor) LabelRole(opts *bind.TransactOpts, roleId uint64, label string) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "labelRole", roleId, label)
}

// LabelRole is a paid mutator transaction binding the contract method 0x853551b8.
//
// Solidity: function labelRole(uint64 roleId, string label) returns()
func (_AccessManager *AccessManagerSession) LabelRole(roleId uint64, label string) (*types.Transaction, error) {
	return _AccessManager.Contract.LabelRole(&_AccessManager.TransactOpts, roleId, label)
}

// LabelRole is a paid mutator transaction binding the contract method 0x853551b8.
//
// Solidity: function labelRole(uint64 roleId, string label) returns()
func (_AccessManager *AccessManagerTransactorSession) LabelRole(roleId uint64, label string) (*types.Transaction, error) {
	return _AccessManager.Contract.LabelRole(&_AccessManager.TransactOpts, roleId, label)
}

// Multicall is a paid mutator transaction binding the contract method 0xac9650d8.
//
// Solidity: function multicall(bytes[] data) returns(bytes[] results)
func (_AccessManager *AccessManagerTransactor) Multicall(opts *bind.TransactOpts, data [][]byte) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "multicall", data)
}

// Multicall is a paid mutator transaction binding the contract method 0xac9650d8.
//
// Solidity: function multicall(bytes[] data) returns(bytes[] results)
func (_AccessManager *AccessManagerSession) Multicall(data [][]byte) (*types.Transaction, error) {
	return _AccessManager.Contract.Multicall(&_AccessManager.TransactOpts, data)
}

// Multicall is a paid mutator transaction binding the contract method 0xac9650d8.
//
// Solidity: function multicall(bytes[] data) returns(bytes[] results)
func (_AccessManager *AccessManagerTransactorSession) Multicall(data [][]byte) (*types.Transaction, error) {
	return _AccessManager.Contract.Multicall(&_AccessManager.TransactOpts, data)
}

// RenounceRole is a paid mutator transaction binding the contract method 0xfe0776f5.
//
// Solidity: function renounceRole(uint64 roleId, address callerConfirmation) returns()
func (_AccessManager *AccessManagerTransactor) RenounceRole(opts *bind.TransactOpts, roleId uint64, callerConfirmation common.Address) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "renounceRole", roleId, callerConfirmation)
}

// RenounceRole is a paid mutator transaction binding the contract method 0xfe0776f5.
//
// Solidity: function renounceRole(uint64 roleId, address callerConfirmation) returns()
func (_AccessManager *AccessManagerSession) RenounceRole(roleId uint64, callerConfirmation common.Address) (*types.Transaction, error) {
	return _AccessManager.Contract.RenounceRole(&_AccessManager.TransactOpts, roleId, callerConfirmation)
}

// RenounceRole is a paid mutator transaction binding the contract method 0xfe0776f5.
//
// Solidity: function renounceRole(uint64 roleId, address callerConfirmation) returns()
func (_AccessManager *AccessManagerTransactorSession) RenounceRole(roleId uint64, callerConfirmation common.Address) (*types.Transaction, error) {
	return _AccessManager.Contract.RenounceRole(&_AccessManager.TransactOpts, roleId, callerConfirmation)
}

// RevokeRole is a paid mutator transaction binding the contract method 0xb7d2b162.
//
// Solidity: function revokeRole(uint64 roleId, address account) returns()
func (_AccessManager *AccessManagerTransactor) RevokeRole(opts *bind.TransactOpts, roleId uint64, account common.Address) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "revokeRole", roleId, account)
}

// RevokeRole is a paid mutator transaction binding the contract method 0xb7d2b162.
//
// Solidity: function revokeRole(uint64 roleId, address account) returns()
func (_AccessManager *AccessManagerSession) RevokeRole(roleId uint64, account common.Address) (*types.Transaction, error) {
	return _AccessManager.Contract.RevokeRole(&_AccessManager.TransactOpts, roleId, account)
}

// RevokeRole is a paid mutator transaction binding the contract method 0xb7d2b162.
//
// Solidity: function revokeRole(uint64 roleId, address account) returns()
func (_AccessManager *AccessManagerTransactorSession) RevokeRole(roleId uint64, account common.Address) (*types.Transaction, error) {
	return _AccessManager.Contract.RevokeRole(&_AccessManager.TransactOpts, roleId, account)
}

// Schedule is a paid mutator transaction binding the contract method 0xf801a698.
//
// Solidity: function schedule(address target, bytes data, uint48 when) returns(bytes32 operationId, uint32 nonce)
func (_AccessManager *AccessManagerTransactor) Schedule(opts *bind.TransactOpts, target common.Address, data []byte, when *big.Int) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "schedule", target, data, when)
}

// Schedule is a paid mutator transaction binding the contract method 0xf801a698.
//
// Solidity: function schedule(address target, bytes data, uint48 when) returns(bytes32 operationId, uint32 nonce)
func (_AccessManager *AccessManagerSession) Schedule(target common.Address, data []byte, when *big.Int) (*types.Transaction, error) {
	return _AccessManager.Contract.Schedule(&_AccessManager.TransactOpts, target, data, when)
}

// Schedule is a paid mutator transaction binding the contract method 0xf801a698.
//
// Solidity: function schedule(address target, bytes data, uint48 when) returns(bytes32 operationId, uint32 nonce)
func (_AccessManager *AccessManagerTransactorSession) Schedule(target common.Address, data []byte, when *big.Int) (*types.Transaction, error) {
	return _AccessManager.Contract.Schedule(&_AccessManager.TransactOpts, target, data, when)
}

// SetGrantDelay is a paid mutator transaction binding the contract method 0xa64d95ce.
//
// Solidity: function setGrantDelay(uint64 roleId, uint32 newDelay) returns()
func (_AccessManager *AccessManagerTransactor) SetGrantDelay(opts *bind.TransactOpts, roleId uint64, newDelay uint32) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "setGrantDelay", roleId, newDelay)
}

// SetGrantDelay is a paid mutator transaction binding the contract method 0xa64d95ce.
//
// Solidity: function setGrantDelay(uint64 roleId, uint32 newDelay) returns()
func (_AccessManager *AccessManagerSession) SetGrantDelay(roleId uint64, newDelay uint32) (*types.Transaction, error) {
	return _AccessManager.Contract.SetGrantDelay(&_AccessManager.TransactOpts, roleId, newDelay)
}

// SetGrantDelay is a paid mutator transaction binding the contract method 0xa64d95ce.
//
// Solidity: function setGrantDelay(uint64 roleId, uint32 newDelay) returns()
func (_AccessManager *AccessManagerTransactorSession) SetGrantDelay(roleId uint64, newDelay uint32) (*types.Transaction, error) {
	return _AccessManager.Contract.SetGrantDelay(&_AccessManager.TransactOpts, roleId, newDelay)
}

// SetRoleAdmin is a paid mutator transaction binding the contract method 0x30cae187.
//
// Solidity: function setRoleAdmin(uint64 roleId, uint64 admin) returns()
func (_AccessManager *AccessManagerTransactor) SetRoleAdmin(opts *bind.TransactOpts, roleId uint64, admin uint64) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "setRoleAdmin", roleId, admin)
}

// SetRoleAdmin is a paid mutator transaction binding the contract method 0x30cae187.
//
// Solidity: function setRoleAdmin(uint64 roleId, uint64 admin) returns()
func (_AccessManager *AccessManagerSession) SetRoleAdmin(roleId uint64, admin uint64) (*types.Transaction, error) {
	return _AccessManager.Contract.SetRoleAdmin(&_AccessManager.TransactOpts, roleId, admin)
}

// SetRoleAdmin is a paid mutator transaction binding the contract method 0x30cae187.
//
// Solidity: function setRoleAdmin(uint64 roleId, uint64 admin) returns()
func (_AccessManager *AccessManagerTransactorSession) SetRoleAdmin(roleId uint64, admin uint64) (*types.Transaction, error) {
	return _AccessManager.Contract.SetRoleAdmin(&_AccessManager.TransactOpts, roleId, admin)
}

// SetRoleGuardian is a paid mutator transaction binding the contract method 0x52962952.
//
// Solidity: function setRoleGuardian(uint64 roleId, uint64 guardian) returns()
func (_AccessManager *AccessManagerTransactor) SetRoleGuardian(opts *bind.TransactOpts, roleId uint64, guardian uint64) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "setRoleGuardian", roleId, guardian)
}

// SetRoleGuardian is a paid mutator transaction binding the contract method 0x52962952.
//
// Solidity: function setRoleGuardian(uint64 roleId, uint64 guardian) returns()
func (_AccessManager *AccessManagerSession) SetRoleGuardian(roleId uint64, guardian uint64) (*types.Transaction, error) {
	return _AccessManager.Contract.SetRoleGuardian(&_AccessManager.TransactOpts, roleId, guardian)
}

// SetRoleGuardian is a paid mutator transaction binding the contract method 0x52962952.
//
// Solidity: function setRoleGuardian(uint64 roleId, uint64 guardian) returns()
func (_AccessManager *AccessManagerTransactorSession) SetRoleGuardian(roleId uint64, guardian uint64) (*types.Transaction, error) {
	return _AccessManager.Contract.SetRoleGuardian(&_AccessManager.TransactOpts, roleId, guardian)
}

// SetTargetAdminDelay is a paid mutator transaction binding the contract method 0xd22b5989.
//
// Solidity: function setTargetAdminDelay(address target, uint32 newDelay) returns()
func (_AccessManager *AccessManagerTransactor) SetTargetAdminDelay(opts *bind.TransactOpts, target common.Address, newDelay uint32) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "setTargetAdminDelay", target, newDelay)
}

// SetTargetAdminDelay is a paid mutator transaction binding the contract method 0xd22b5989.
//
// Solidity: function setTargetAdminDelay(address target, uint32 newDelay) returns()
func (_AccessManager *AccessManagerSession) SetTargetAdminDelay(target common.Address, newDelay uint32) (*types.Transaction, error) {
	return _AccessManager.Contract.SetTargetAdminDelay(&_AccessManager.TransactOpts, target, newDelay)
}

// SetTargetAdminDelay is a paid mutator transaction binding the contract method 0xd22b5989.
//
// Solidity: function setTargetAdminDelay(address target, uint32 newDelay) returns()
func (_AccessManager *AccessManagerTransactorSession) SetTargetAdminDelay(target common.Address, newDelay uint32) (*types.Transaction, error) {
	return _AccessManager.Contract.SetTargetAdminDelay(&_AccessManager.TransactOpts, target, newDelay)
}

// SetTargetClosed is a paid mutator transaction binding the contract method 0x167bd395.
//
// Solidity: function setTargetClosed(address target, bool closed) returns()
func (_AccessManager *AccessManagerTransactor) SetTargetClosed(opts *bind.TransactOpts, target common.Address, closed bool) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "setTargetClosed", target, closed)
}

// SetTargetClosed is a paid mutator transaction binding the contract method 0x167bd395.
//
// Solidity: function setTargetClosed(address target, bool closed) returns()
func (_AccessManager *AccessManagerSession) SetTargetClosed(target common.Address, closed bool) (*types.Transaction, error) {
	return _AccessManager.Contract.SetTargetClosed(&_AccessManager.TransactOpts, target, closed)
}

// SetTargetClosed is a paid mutator transaction binding the contract method 0x167bd395.
//
// Solidity: function setTargetClosed(address target, bool closed) returns()
func (_AccessManager *AccessManagerTransactorSession) SetTargetClosed(target common.Address, closed bool) (*types.Transaction, error) {
	return _AccessManager.Contract.SetTargetClosed(&_AccessManager.TransactOpts, target, closed)
}

// SetTargetFunctionRole is a paid mutator transaction binding the contract method 0x08d6122d.
//
// Solidity: function setTargetFunctionRole(address target, bytes4[] selectors, uint64 roleId) returns()
func (_AccessManager *AccessManagerTransactor) SetTargetFunctionRole(opts *bind.TransactOpts, target common.Address, selectors [][4]byte, roleId uint64) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "setTargetFunctionRole", target, selectors, roleId)
}

// SetTargetFunctionRole is a paid mutator transaction binding the contract method 0x08d6122d.
//
// Solidity: function setTargetFunctionRole(address target, bytes4[] selectors, uint64 roleId) returns()
func (_AccessManager *AccessManagerSession) SetTargetFunctionRole(target common.Address, selectors [][4]byte, roleId uint64) (*types.Transaction, error) {
	return _AccessManager.Contract.SetTargetFunctionRole(&_AccessManager.TransactOpts, target, selectors, roleId)
}

// SetTargetFunctionRole is a paid mutator transaction binding the contract method 0x08d6122d.
//
// Solidity: function setTargetFunctionRole(address target, bytes4[] selectors, uint64 roleId) returns()
func (_AccessManager *AccessManagerTransactorSession) SetTargetFunctionRole(target common.Address, selectors [][4]byte, roleId uint64) (*types.Transaction, error) {
	return _AccessManager.Contract.SetTargetFunctionRole(&_AccessManager.TransactOpts, target, selectors, roleId)
}

// UpdateAuthority is a paid mutator transaction binding the contract method 0x18ff183c.
//
// Solidity: function updateAuthority(address target, address newAuthority) returns()
func (_AccessManager *AccessManagerTransactor) UpdateAuthority(opts *bind.TransactOpts, target common.Address, newAuthority common.Address) (*types.Transaction, error) {
	return _AccessManager.contract.Transact(opts, "updateAuthority", target, newAuthority)
}

// UpdateAuthority is a paid mutator transaction binding the contract method 0x18ff183c.
//
// Solidity: function updateAuthority(address target, address newAuthority) returns()
func (_AccessManager *AccessManagerSession) UpdateAuthority(target common.Address, newAuthority common.Address) (*types.Transaction, error) {
	return _AccessManager.Contract.UpdateAuthority(&_AccessManager.TransactOpts, target, newAuthority)
}

// UpdateAuthority is a paid mutator transaction binding the contract method 0x18ff183c.
//
// Solidity: function updateAuthority(address target, address newAuthority) returns()
func (_AccessManager *AccessManagerTransactorSession) UpdateAuthority(target common.Address, newAuthority common.Address) (*types.Transaction, error) {
	return _AccessManager.Contract.UpdateAuthority(&_AccessManager.TransactOpts, target, newAuthority)
}

// AccessManagerOperationCanceledIterator is returned from FilterOperationCanceled and is used to iterate over the raw logs and unpacked data for OperationCanceled events raised by the AccessManager contract.
type AccessManagerOperationCanceledIterator struct {
	Event *AccessManagerOperationCanceled // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerOperationCanceledIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerOperationCanceled)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerOperationCanceled)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerOperationCanceledIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerOperationCanceledIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerOperationCanceled represents a OperationCanceled event raised by the AccessManager contract.
type AccessManagerOperationCanceled struct {
	OperationId [32]byte
	Nonce       uint32
	Raw         types.Log // Blockchain specific contextual infos
}

// FilterOperationCanceled is a free log retrieval operation binding the contract event 0xbd9ac67a6e2f6463b80927326310338bcbb4bdb7936ce1365ea3e01067e7b9f7.
//
// Solidity: event OperationCanceled(bytes32 indexed operationId, uint32 indexed nonce)
func (_AccessManager *AccessManagerFilterer) FilterOperationCanceled(opts *bind.FilterOpts, operationId [][32]byte, nonce []uint32) (*AccessManagerOperationCanceledIterator, error) {

	var operationIdRule []interface{}
	for _, operationIdItem := range operationId {
		operationIdRule = append(operationIdRule, operationIdItem)
	}
	var nonceRule []interface{}
	for _, nonceItem := range nonce {
		nonceRule = append(nonceRule, nonceItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "OperationCanceled", operationIdRule, nonceRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerOperationCanceledIterator{contract: _AccessManager.contract, event: "OperationCanceled", logs: logs, sub: sub}, nil
}

// WatchOperationCanceled is a free log subscription operation binding the contract event 0xbd9ac67a6e2f6463b80927326310338bcbb4bdb7936ce1365ea3e01067e7b9f7.
//
// Solidity: event OperationCanceled(bytes32 indexed operationId, uint32 indexed nonce)
func (_AccessManager *AccessManagerFilterer) WatchOperationCanceled(opts *bind.WatchOpts, sink chan<- *AccessManagerOperationCanceled, operationId [][32]byte, nonce []uint32) (event.Subscription, error) {

	var operationIdRule []interface{}
	for _, operationIdItem := range operationId {
		operationIdRule = append(operationIdRule, operationIdItem)
	}
	var nonceRule []interface{}
	for _, nonceItem := range nonce {
		nonceRule = append(nonceRule, nonceItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "OperationCanceled", operationIdRule, nonceRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerOperationCanceled)
				if err := _AccessManager.contract.UnpackLog(event, "OperationCanceled", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseOperationCanceled is a log parse operation binding the contract event 0xbd9ac67a6e2f6463b80927326310338bcbb4bdb7936ce1365ea3e01067e7b9f7.
//
// Solidity: event OperationCanceled(bytes32 indexed operationId, uint32 indexed nonce)
func (_AccessManager *AccessManagerFilterer) ParseOperationCanceled(log types.Log) (*AccessManagerOperationCanceled, error) {
	event := new(AccessManagerOperationCanceled)
	if err := _AccessManager.contract.UnpackLog(event, "OperationCanceled", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerOperationExecutedIterator is returned from FilterOperationExecuted and is used to iterate over the raw logs and unpacked data for OperationExecuted events raised by the AccessManager contract.
type AccessManagerOperationExecutedIterator struct {
	Event *AccessManagerOperationExecuted // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerOperationExecutedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerOperationExecuted)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerOperationExecuted)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerOperationExecutedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerOperationExecutedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerOperationExecuted represents a OperationExecuted event raised by the AccessManager contract.
type AccessManagerOperationExecuted struct {
	OperationId [32]byte
	Nonce       uint32
	Raw         types.Log // Blockchain specific contextual infos
}

// FilterOperationExecuted is a free log retrieval operation binding the contract event 0x76a2a46953689d4861a5d3f6ed883ad7e6af674a21f8e162707159fc9dde614d.
//
// Solidity: event OperationExecuted(bytes32 indexed operationId, uint32 indexed nonce)
func (_AccessManager *AccessManagerFilterer) FilterOperationExecuted(opts *bind.FilterOpts, operationId [][32]byte, nonce []uint32) (*AccessManagerOperationExecutedIterator, error) {

	var operationIdRule []interface{}
	for _, operationIdItem := range operationId {
		operationIdRule = append(operationIdRule, operationIdItem)
	}
	var nonceRule []interface{}
	for _, nonceItem := range nonce {
		nonceRule = append(nonceRule, nonceItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "OperationExecuted", operationIdRule, nonceRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerOperationExecutedIterator{contract: _AccessManager.contract, event: "OperationExecuted", logs: logs, sub: sub}, nil
}

// WatchOperationExecuted is a free log subscription operation binding the contract event 0x76a2a46953689d4861a5d3f6ed883ad7e6af674a21f8e162707159fc9dde614d.
//
// Solidity: event OperationExecuted(bytes32 indexed operationId, uint32 indexed nonce)
func (_AccessManager *AccessManagerFilterer) WatchOperationExecuted(opts *bind.WatchOpts, sink chan<- *AccessManagerOperationExecuted, operationId [][32]byte, nonce []uint32) (event.Subscription, error) {

	var operationIdRule []interface{}
	for _, operationIdItem := range operationId {
		operationIdRule = append(operationIdRule, operationIdItem)
	}
	var nonceRule []interface{}
	for _, nonceItem := range nonce {
		nonceRule = append(nonceRule, nonceItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "OperationExecuted", operationIdRule, nonceRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerOperationExecuted)
				if err := _AccessManager.contract.UnpackLog(event, "OperationExecuted", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseOperationExecuted is a log parse operation binding the contract event 0x76a2a46953689d4861a5d3f6ed883ad7e6af674a21f8e162707159fc9dde614d.
//
// Solidity: event OperationExecuted(bytes32 indexed operationId, uint32 indexed nonce)
func (_AccessManager *AccessManagerFilterer) ParseOperationExecuted(log types.Log) (*AccessManagerOperationExecuted, error) {
	event := new(AccessManagerOperationExecuted)
	if err := _AccessManager.contract.UnpackLog(event, "OperationExecuted", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerOperationScheduledIterator is returned from FilterOperationScheduled and is used to iterate over the raw logs and unpacked data for OperationScheduled events raised by the AccessManager contract.
type AccessManagerOperationScheduledIterator struct {
	Event *AccessManagerOperationScheduled // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerOperationScheduledIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerOperationScheduled)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerOperationScheduled)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerOperationScheduledIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerOperationScheduledIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerOperationScheduled represents a OperationScheduled event raised by the AccessManager contract.
type AccessManagerOperationScheduled struct {
	OperationId [32]byte
	Nonce       uint32
	Schedule    *big.Int
	Caller      common.Address
	Target      common.Address
	Data        []byte
	Raw         types.Log // Blockchain specific contextual infos
}

// FilterOperationScheduled is a free log retrieval operation binding the contract event 0x82a2da5dee54ea8021c6545b4444620291e07ee83be6dd57edb175062715f3b4.
//
// Solidity: event OperationScheduled(bytes32 indexed operationId, uint32 indexed nonce, uint48 schedule, address caller, address target, bytes data)
func (_AccessManager *AccessManagerFilterer) FilterOperationScheduled(opts *bind.FilterOpts, operationId [][32]byte, nonce []uint32) (*AccessManagerOperationScheduledIterator, error) {

	var operationIdRule []interface{}
	for _, operationIdItem := range operationId {
		operationIdRule = append(operationIdRule, operationIdItem)
	}
	var nonceRule []interface{}
	for _, nonceItem := range nonce {
		nonceRule = append(nonceRule, nonceItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "OperationScheduled", operationIdRule, nonceRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerOperationScheduledIterator{contract: _AccessManager.contract, event: "OperationScheduled", logs: logs, sub: sub}, nil
}

// WatchOperationScheduled is a free log subscription operation binding the contract event 0x82a2da5dee54ea8021c6545b4444620291e07ee83be6dd57edb175062715f3b4.
//
// Solidity: event OperationScheduled(bytes32 indexed operationId, uint32 indexed nonce, uint48 schedule, address caller, address target, bytes data)
func (_AccessManager *AccessManagerFilterer) WatchOperationScheduled(opts *bind.WatchOpts, sink chan<- *AccessManagerOperationScheduled, operationId [][32]byte, nonce []uint32) (event.Subscription, error) {

	var operationIdRule []interface{}
	for _, operationIdItem := range operationId {
		operationIdRule = append(operationIdRule, operationIdItem)
	}
	var nonceRule []interface{}
	for _, nonceItem := range nonce {
		nonceRule = append(nonceRule, nonceItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "OperationScheduled", operationIdRule, nonceRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerOperationScheduled)
				if err := _AccessManager.contract.UnpackLog(event, "OperationScheduled", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseOperationScheduled is a log parse operation binding the contract event 0x82a2da5dee54ea8021c6545b4444620291e07ee83be6dd57edb175062715f3b4.
//
// Solidity: event OperationScheduled(bytes32 indexed operationId, uint32 indexed nonce, uint48 schedule, address caller, address target, bytes data)
func (_AccessManager *AccessManagerFilterer) ParseOperationScheduled(log types.Log) (*AccessManagerOperationScheduled, error) {
	event := new(AccessManagerOperationScheduled)
	if err := _AccessManager.contract.UnpackLog(event, "OperationScheduled", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerRoleAdminChangedIterator is returned from FilterRoleAdminChanged and is used to iterate over the raw logs and unpacked data for RoleAdminChanged events raised by the AccessManager contract.
type AccessManagerRoleAdminChangedIterator struct {
	Event *AccessManagerRoleAdminChanged // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerRoleAdminChangedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerRoleAdminChanged)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerRoleAdminChanged)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerRoleAdminChangedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerRoleAdminChangedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerRoleAdminChanged represents a RoleAdminChanged event raised by the AccessManager contract.
type AccessManagerRoleAdminChanged struct {
	RoleId uint64
	Admin  uint64
	Raw    types.Log // Blockchain specific contextual infos
}

// FilterRoleAdminChanged is a free log retrieval operation binding the contract event 0x1fd6dd7631312dfac2205b52913f99de03b4d7e381d5d27d3dbfe0713e6e6340.
//
// Solidity: event RoleAdminChanged(uint64 indexed roleId, uint64 indexed admin)
func (_AccessManager *AccessManagerFilterer) FilterRoleAdminChanged(opts *bind.FilterOpts, roleId []uint64, admin []uint64) (*AccessManagerRoleAdminChangedIterator, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}
	var adminRule []interface{}
	for _, adminItem := range admin {
		adminRule = append(adminRule, adminItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "RoleAdminChanged", roleIdRule, adminRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerRoleAdminChangedIterator{contract: _AccessManager.contract, event: "RoleAdminChanged", logs: logs, sub: sub}, nil
}

// WatchRoleAdminChanged is a free log subscription operation binding the contract event 0x1fd6dd7631312dfac2205b52913f99de03b4d7e381d5d27d3dbfe0713e6e6340.
//
// Solidity: event RoleAdminChanged(uint64 indexed roleId, uint64 indexed admin)
func (_AccessManager *AccessManagerFilterer) WatchRoleAdminChanged(opts *bind.WatchOpts, sink chan<- *AccessManagerRoleAdminChanged, roleId []uint64, admin []uint64) (event.Subscription, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}
	var adminRule []interface{}
	for _, adminItem := range admin {
		adminRule = append(adminRule, adminItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "RoleAdminChanged", roleIdRule, adminRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerRoleAdminChanged)
				if err := _AccessManager.contract.UnpackLog(event, "RoleAdminChanged", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRoleAdminChanged is a log parse operation binding the contract event 0x1fd6dd7631312dfac2205b52913f99de03b4d7e381d5d27d3dbfe0713e6e6340.
//
// Solidity: event RoleAdminChanged(uint64 indexed roleId, uint64 indexed admin)
func (_AccessManager *AccessManagerFilterer) ParseRoleAdminChanged(log types.Log) (*AccessManagerRoleAdminChanged, error) {
	event := new(AccessManagerRoleAdminChanged)
	if err := _AccessManager.contract.UnpackLog(event, "RoleAdminChanged", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerRoleGrantDelayChangedIterator is returned from FilterRoleGrantDelayChanged and is used to iterate over the raw logs and unpacked data for RoleGrantDelayChanged events raised by the AccessManager contract.
type AccessManagerRoleGrantDelayChangedIterator struct {
	Event *AccessManagerRoleGrantDelayChanged // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerRoleGrantDelayChangedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerRoleGrantDelayChanged)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerRoleGrantDelayChanged)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerRoleGrantDelayChangedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerRoleGrantDelayChangedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerRoleGrantDelayChanged represents a RoleGrantDelayChanged event raised by the AccessManager contract.
type AccessManagerRoleGrantDelayChanged struct {
	RoleId uint64
	Delay  uint32
	Since  *big.Int
	Raw    types.Log // Blockchain specific contextual infos
}

// FilterRoleGrantDelayChanged is a free log retrieval operation binding the contract event 0xfeb69018ee8b8fd50ea86348f1267d07673379f72cffdeccec63853ee8ce8b48.
//
// Solidity: event RoleGrantDelayChanged(uint64 indexed roleId, uint32 delay, uint48 since)
func (_AccessManager *AccessManagerFilterer) FilterRoleGrantDelayChanged(opts *bind.FilterOpts, roleId []uint64) (*AccessManagerRoleGrantDelayChangedIterator, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "RoleGrantDelayChanged", roleIdRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerRoleGrantDelayChangedIterator{contract: _AccessManager.contract, event: "RoleGrantDelayChanged", logs: logs, sub: sub}, nil
}

// WatchRoleGrantDelayChanged is a free log subscription operation binding the contract event 0xfeb69018ee8b8fd50ea86348f1267d07673379f72cffdeccec63853ee8ce8b48.
//
// Solidity: event RoleGrantDelayChanged(uint64 indexed roleId, uint32 delay, uint48 since)
func (_AccessManager *AccessManagerFilterer) WatchRoleGrantDelayChanged(opts *bind.WatchOpts, sink chan<- *AccessManagerRoleGrantDelayChanged, roleId []uint64) (event.Subscription, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "RoleGrantDelayChanged", roleIdRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerRoleGrantDelayChanged)
				if err := _AccessManager.contract.UnpackLog(event, "RoleGrantDelayChanged", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRoleGrantDelayChanged is a log parse operation binding the contract event 0xfeb69018ee8b8fd50ea86348f1267d07673379f72cffdeccec63853ee8ce8b48.
//
// Solidity: event RoleGrantDelayChanged(uint64 indexed roleId, uint32 delay, uint48 since)
func (_AccessManager *AccessManagerFilterer) ParseRoleGrantDelayChanged(log types.Log) (*AccessManagerRoleGrantDelayChanged, error) {
	event := new(AccessManagerRoleGrantDelayChanged)
	if err := _AccessManager.contract.UnpackLog(event, "RoleGrantDelayChanged", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerRoleGrantedIterator is returned from FilterRoleGranted and is used to iterate over the raw logs and unpacked data for RoleGranted events raised by the AccessManager contract.
type AccessManagerRoleGrantedIterator struct {
	Event *AccessManagerRoleGranted // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerRoleGrantedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerRoleGranted)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerRoleGranted)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerRoleGrantedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerRoleGrantedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerRoleGranted represents a RoleGranted event raised by the AccessManager contract.
type AccessManagerRoleGranted struct {
	RoleId    uint64
	Account   common.Address
	Delay     uint32
	Since     *big.Int
	NewMember bool
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterRoleGranted is a free log retrieval operation binding the contract event 0xf98448b987f1428e0e230e1f3c6e2ce15b5693eaf31827fbd0b1ec4b424ae7cf.
//
// Solidity: event RoleGranted(uint64 indexed roleId, address indexed account, uint32 delay, uint48 since, bool newMember)
func (_AccessManager *AccessManagerFilterer) FilterRoleGranted(opts *bind.FilterOpts, roleId []uint64, account []common.Address) (*AccessManagerRoleGrantedIterator, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "RoleGranted", roleIdRule, accountRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerRoleGrantedIterator{contract: _AccessManager.contract, event: "RoleGranted", logs: logs, sub: sub}, nil
}

// WatchRoleGranted is a free log subscription operation binding the contract event 0xf98448b987f1428e0e230e1f3c6e2ce15b5693eaf31827fbd0b1ec4b424ae7cf.
//
// Solidity: event RoleGranted(uint64 indexed roleId, address indexed account, uint32 delay, uint48 since, bool newMember)
func (_AccessManager *AccessManagerFilterer) WatchRoleGranted(opts *bind.WatchOpts, sink chan<- *AccessManagerRoleGranted, roleId []uint64, account []common.Address) (event.Subscription, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "RoleGranted", roleIdRule, accountRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerRoleGranted)
				if err := _AccessManager.contract.UnpackLog(event, "RoleGranted", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRoleGranted is a log parse operation binding the contract event 0xf98448b987f1428e0e230e1f3c6e2ce15b5693eaf31827fbd0b1ec4b424ae7cf.
//
// Solidity: event RoleGranted(uint64 indexed roleId, address indexed account, uint32 delay, uint48 since, bool newMember)
func (_AccessManager *AccessManagerFilterer) ParseRoleGranted(log types.Log) (*AccessManagerRoleGranted, error) {
	event := new(AccessManagerRoleGranted)
	if err := _AccessManager.contract.UnpackLog(event, "RoleGranted", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerRoleGuardianChangedIterator is returned from FilterRoleGuardianChanged and is used to iterate over the raw logs and unpacked data for RoleGuardianChanged events raised by the AccessManager contract.
type AccessManagerRoleGuardianChangedIterator struct {
	Event *AccessManagerRoleGuardianChanged // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerRoleGuardianChangedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerRoleGuardianChanged)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerRoleGuardianChanged)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerRoleGuardianChangedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerRoleGuardianChangedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerRoleGuardianChanged represents a RoleGuardianChanged event raised by the AccessManager contract.
type AccessManagerRoleGuardianChanged struct {
	RoleId   uint64
	Guardian uint64
	Raw      types.Log // Blockchain specific contextual infos
}

// FilterRoleGuardianChanged is a free log retrieval operation binding the contract event 0x7a8059630b897b5de4c08ade69f8b90c3ead1f8596d62d10b6c4d14a0afb4ae2.
//
// Solidity: event RoleGuardianChanged(uint64 indexed roleId, uint64 indexed guardian)
func (_AccessManager *AccessManagerFilterer) FilterRoleGuardianChanged(opts *bind.FilterOpts, roleId []uint64, guardian []uint64) (*AccessManagerRoleGuardianChangedIterator, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}
	var guardianRule []interface{}
	for _, guardianItem := range guardian {
		guardianRule = append(guardianRule, guardianItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "RoleGuardianChanged", roleIdRule, guardianRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerRoleGuardianChangedIterator{contract: _AccessManager.contract, event: "RoleGuardianChanged", logs: logs, sub: sub}, nil
}

// WatchRoleGuardianChanged is a free log subscription operation binding the contract event 0x7a8059630b897b5de4c08ade69f8b90c3ead1f8596d62d10b6c4d14a0afb4ae2.
//
// Solidity: event RoleGuardianChanged(uint64 indexed roleId, uint64 indexed guardian)
func (_AccessManager *AccessManagerFilterer) WatchRoleGuardianChanged(opts *bind.WatchOpts, sink chan<- *AccessManagerRoleGuardianChanged, roleId []uint64, guardian []uint64) (event.Subscription, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}
	var guardianRule []interface{}
	for _, guardianItem := range guardian {
		guardianRule = append(guardianRule, guardianItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "RoleGuardianChanged", roleIdRule, guardianRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerRoleGuardianChanged)
				if err := _AccessManager.contract.UnpackLog(event, "RoleGuardianChanged", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRoleGuardianChanged is a log parse operation binding the contract event 0x7a8059630b897b5de4c08ade69f8b90c3ead1f8596d62d10b6c4d14a0afb4ae2.
//
// Solidity: event RoleGuardianChanged(uint64 indexed roleId, uint64 indexed guardian)
func (_AccessManager *AccessManagerFilterer) ParseRoleGuardianChanged(log types.Log) (*AccessManagerRoleGuardianChanged, error) {
	event := new(AccessManagerRoleGuardianChanged)
	if err := _AccessManager.contract.UnpackLog(event, "RoleGuardianChanged", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerRoleLabelIterator is returned from FilterRoleLabel and is used to iterate over the raw logs and unpacked data for RoleLabel events raised by the AccessManager contract.
type AccessManagerRoleLabelIterator struct {
	Event *AccessManagerRoleLabel // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerRoleLabelIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerRoleLabel)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerRoleLabel)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerRoleLabelIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerRoleLabelIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerRoleLabel represents a RoleLabel event raised by the AccessManager contract.
type AccessManagerRoleLabel struct {
	RoleId uint64
	Label  string
	Raw    types.Log // Blockchain specific contextual infos
}

// FilterRoleLabel is a free log retrieval operation binding the contract event 0x1256f5b5ecb89caec12db449738f2fbcd1ba5806cf38f35413f4e5c15bf6a450.
//
// Solidity: event RoleLabel(uint64 indexed roleId, string label)
func (_AccessManager *AccessManagerFilterer) FilterRoleLabel(opts *bind.FilterOpts, roleId []uint64) (*AccessManagerRoleLabelIterator, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "RoleLabel", roleIdRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerRoleLabelIterator{contract: _AccessManager.contract, event: "RoleLabel", logs: logs, sub: sub}, nil
}

// WatchRoleLabel is a free log subscription operation binding the contract event 0x1256f5b5ecb89caec12db449738f2fbcd1ba5806cf38f35413f4e5c15bf6a450.
//
// Solidity: event RoleLabel(uint64 indexed roleId, string label)
func (_AccessManager *AccessManagerFilterer) WatchRoleLabel(opts *bind.WatchOpts, sink chan<- *AccessManagerRoleLabel, roleId []uint64) (event.Subscription, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "RoleLabel", roleIdRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerRoleLabel)
				if err := _AccessManager.contract.UnpackLog(event, "RoleLabel", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRoleLabel is a log parse operation binding the contract event 0x1256f5b5ecb89caec12db449738f2fbcd1ba5806cf38f35413f4e5c15bf6a450.
//
// Solidity: event RoleLabel(uint64 indexed roleId, string label)
func (_AccessManager *AccessManagerFilterer) ParseRoleLabel(log types.Log) (*AccessManagerRoleLabel, error) {
	event := new(AccessManagerRoleLabel)
	if err := _AccessManager.contract.UnpackLog(event, "RoleLabel", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerRoleRevokedIterator is returned from FilterRoleRevoked and is used to iterate over the raw logs and unpacked data for RoleRevoked events raised by the AccessManager contract.
type AccessManagerRoleRevokedIterator struct {
	Event *AccessManagerRoleRevoked // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerRoleRevokedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerRoleRevoked)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerRoleRevoked)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerRoleRevokedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerRoleRevokedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerRoleRevoked represents a RoleRevoked event raised by the AccessManager contract.
type AccessManagerRoleRevoked struct {
	RoleId  uint64
	Account common.Address
	Raw     types.Log // Blockchain specific contextual infos
}

// FilterRoleRevoked is a free log retrieval operation binding the contract event 0xf229baa593af28c41b1d16b748cd7688f0c83aaf92d4be41c44005defe84c166.
//
// Solidity: event RoleRevoked(uint64 indexed roleId, address indexed account)
func (_AccessManager *AccessManagerFilterer) FilterRoleRevoked(opts *bind.FilterOpts, roleId []uint64, account []common.Address) (*AccessManagerRoleRevokedIterator, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "RoleRevoked", roleIdRule, accountRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerRoleRevokedIterator{contract: _AccessManager.contract, event: "RoleRevoked", logs: logs, sub: sub}, nil
}

// WatchRoleRevoked is a free log subscription operation binding the contract event 0xf229baa593af28c41b1d16b748cd7688f0c83aaf92d4be41c44005defe84c166.
//
// Solidity: event RoleRevoked(uint64 indexed roleId, address indexed account)
func (_AccessManager *AccessManagerFilterer) WatchRoleRevoked(opts *bind.WatchOpts, sink chan<- *AccessManagerRoleRevoked, roleId []uint64, account []common.Address) (event.Subscription, error) {

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "RoleRevoked", roleIdRule, accountRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerRoleRevoked)
				if err := _AccessManager.contract.UnpackLog(event, "RoleRevoked", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRoleRevoked is a log parse operation binding the contract event 0xf229baa593af28c41b1d16b748cd7688f0c83aaf92d4be41c44005defe84c166.
//
// Solidity: event RoleRevoked(uint64 indexed roleId, address indexed account)
func (_AccessManager *AccessManagerFilterer) ParseRoleRevoked(log types.Log) (*AccessManagerRoleRevoked, error) {
	event := new(AccessManagerRoleRevoked)
	if err := _AccessManager.contract.UnpackLog(event, "RoleRevoked", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerTargetAdminDelayUpdatedIterator is returned from FilterTargetAdminDelayUpdated and is used to iterate over the raw logs and unpacked data for TargetAdminDelayUpdated events raised by the AccessManager contract.
type AccessManagerTargetAdminDelayUpdatedIterator struct {
	Event *AccessManagerTargetAdminDelayUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerTargetAdminDelayUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerTargetAdminDelayUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerTargetAdminDelayUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerTargetAdminDelayUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerTargetAdminDelayUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerTargetAdminDelayUpdated represents a TargetAdminDelayUpdated event raised by the AccessManager contract.
type AccessManagerTargetAdminDelayUpdated struct {
	Target common.Address
	Delay  uint32
	Since  *big.Int
	Raw    types.Log // Blockchain specific contextual infos
}

// FilterTargetAdminDelayUpdated is a free log retrieval operation binding the contract event 0xa56b76017453f399ec2327ba00375dbfb1fd070ff854341ad6191e6a2e2de19c.
//
// Solidity: event TargetAdminDelayUpdated(address indexed target, uint32 delay, uint48 since)
func (_AccessManager *AccessManagerFilterer) FilterTargetAdminDelayUpdated(opts *bind.FilterOpts, target []common.Address) (*AccessManagerTargetAdminDelayUpdatedIterator, error) {

	var targetRule []interface{}
	for _, targetItem := range target {
		targetRule = append(targetRule, targetItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "TargetAdminDelayUpdated", targetRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerTargetAdminDelayUpdatedIterator{contract: _AccessManager.contract, event: "TargetAdminDelayUpdated", logs: logs, sub: sub}, nil
}

// WatchTargetAdminDelayUpdated is a free log subscription operation binding the contract event 0xa56b76017453f399ec2327ba00375dbfb1fd070ff854341ad6191e6a2e2de19c.
//
// Solidity: event TargetAdminDelayUpdated(address indexed target, uint32 delay, uint48 since)
func (_AccessManager *AccessManagerFilterer) WatchTargetAdminDelayUpdated(opts *bind.WatchOpts, sink chan<- *AccessManagerTargetAdminDelayUpdated, target []common.Address) (event.Subscription, error) {

	var targetRule []interface{}
	for _, targetItem := range target {
		targetRule = append(targetRule, targetItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "TargetAdminDelayUpdated", targetRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerTargetAdminDelayUpdated)
				if err := _AccessManager.contract.UnpackLog(event, "TargetAdminDelayUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseTargetAdminDelayUpdated is a log parse operation binding the contract event 0xa56b76017453f399ec2327ba00375dbfb1fd070ff854341ad6191e6a2e2de19c.
//
// Solidity: event TargetAdminDelayUpdated(address indexed target, uint32 delay, uint48 since)
func (_AccessManager *AccessManagerFilterer) ParseTargetAdminDelayUpdated(log types.Log) (*AccessManagerTargetAdminDelayUpdated, error) {
	event := new(AccessManagerTargetAdminDelayUpdated)
	if err := _AccessManager.contract.UnpackLog(event, "TargetAdminDelayUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerTargetClosedIterator is returned from FilterTargetClosed and is used to iterate over the raw logs and unpacked data for TargetClosed events raised by the AccessManager contract.
type AccessManagerTargetClosedIterator struct {
	Event *AccessManagerTargetClosed // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerTargetClosedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerTargetClosed)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerTargetClosed)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerTargetClosedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerTargetClosedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerTargetClosed represents a TargetClosed event raised by the AccessManager contract.
type AccessManagerTargetClosed struct {
	Target common.Address
	Closed bool
	Raw    types.Log // Blockchain specific contextual infos
}

// FilterTargetClosed is a free log retrieval operation binding the contract event 0x90d4e7bb7e5d933792b3562e1741306f8be94837e1348dacef9b6f1df56eb138.
//
// Solidity: event TargetClosed(address indexed target, bool closed)
func (_AccessManager *AccessManagerFilterer) FilterTargetClosed(opts *bind.FilterOpts, target []common.Address) (*AccessManagerTargetClosedIterator, error) {

	var targetRule []interface{}
	for _, targetItem := range target {
		targetRule = append(targetRule, targetItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "TargetClosed", targetRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerTargetClosedIterator{contract: _AccessManager.contract, event: "TargetClosed", logs: logs, sub: sub}, nil
}

// WatchTargetClosed is a free log subscription operation binding the contract event 0x90d4e7bb7e5d933792b3562e1741306f8be94837e1348dacef9b6f1df56eb138.
//
// Solidity: event TargetClosed(address indexed target, bool closed)
func (_AccessManager *AccessManagerFilterer) WatchTargetClosed(opts *bind.WatchOpts, sink chan<- *AccessManagerTargetClosed, target []common.Address) (event.Subscription, error) {

	var targetRule []interface{}
	for _, targetItem := range target {
		targetRule = append(targetRule, targetItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "TargetClosed", targetRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerTargetClosed)
				if err := _AccessManager.contract.UnpackLog(event, "TargetClosed", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseTargetClosed is a log parse operation binding the contract event 0x90d4e7bb7e5d933792b3562e1741306f8be94837e1348dacef9b6f1df56eb138.
//
// Solidity: event TargetClosed(address indexed target, bool closed)
func (_AccessManager *AccessManagerFilterer) ParseTargetClosed(log types.Log) (*AccessManagerTargetClosed, error) {
	event := new(AccessManagerTargetClosed)
	if err := _AccessManager.contract.UnpackLog(event, "TargetClosed", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// AccessManagerTargetFunctionRoleUpdatedIterator is returned from FilterTargetFunctionRoleUpdated and is used to iterate over the raw logs and unpacked data for TargetFunctionRoleUpdated events raised by the AccessManager contract.
type AccessManagerTargetFunctionRoleUpdatedIterator struct {
	Event *AccessManagerTargetFunctionRoleUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *AccessManagerTargetFunctionRoleUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(AccessManagerTargetFunctionRoleUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(AccessManagerTargetFunctionRoleUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *AccessManagerTargetFunctionRoleUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *AccessManagerTargetFunctionRoleUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// AccessManagerTargetFunctionRoleUpdated represents a TargetFunctionRoleUpdated event raised by the AccessManager contract.
type AccessManagerTargetFunctionRoleUpdated struct {
	Target   common.Address
	Selector [4]byte
	RoleId   uint64
	Raw      types.Log // Blockchain specific contextual infos
}

// FilterTargetFunctionRoleUpdated is a free log retrieval operation binding the contract event 0x9ea6790c7dadfd01c9f8b9762b3682607af2c7e79e05a9f9fdf5580dde949151.
//
// Solidity: event TargetFunctionRoleUpdated(address indexed target, bytes4 selector, uint64 indexed roleId)
func (_AccessManager *AccessManagerFilterer) FilterTargetFunctionRoleUpdated(opts *bind.FilterOpts, target []common.Address, roleId []uint64) (*AccessManagerTargetFunctionRoleUpdatedIterator, error) {

	var targetRule []interface{}
	for _, targetItem := range target {
		targetRule = append(targetRule, targetItem)
	}

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}

	logs, sub, err := _AccessManager.contract.FilterLogs(opts, "TargetFunctionRoleUpdated", targetRule, roleIdRule)
	if err != nil {
		return nil, err
	}
	return &AccessManagerTargetFunctionRoleUpdatedIterator{contract: _AccessManager.contract, event: "TargetFunctionRoleUpdated", logs: logs, sub: sub}, nil
}

// WatchTargetFunctionRoleUpdated is a free log subscription operation binding the contract event 0x9ea6790c7dadfd01c9f8b9762b3682607af2c7e79e05a9f9fdf5580dde949151.
//
// Solidity: event TargetFunctionRoleUpdated(address indexed target, bytes4 selector, uint64 indexed roleId)
func (_AccessManager *AccessManagerFilterer) WatchTargetFunctionRoleUpdated(opts *bind.WatchOpts, sink chan<- *AccessManagerTargetFunctionRoleUpdated, target []common.Address, roleId []uint64) (event.Subscription, error) {

	var targetRule []interface{}
	for _, targetItem := range target {
		targetRule = append(targetRule, targetItem)
	}

	var roleIdRule []interface{}
	for _, roleIdItem := range roleId {
		roleIdRule = append(roleIdRule, roleIdItem)
	}

	logs, sub, err := _AccessManager.contract.WatchLogs(opts, "TargetFunctionRoleUpdated", targetRule, roleIdRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(AccessManagerTargetFunctionRoleUpdated)
				if err := _AccessManager.contract.UnpackLog(event, "TargetFunctionRoleUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseTargetFunctionRoleUpdated is a log parse operation binding the contract event 0x9ea6790c7dadfd01c9f8b9762b3682607af2c7e79e05a9f9fdf5580dde949151.
//
// Solidity: event TargetFunctionRoleUpdated(address indexed target, bytes4 selector, uint64 indexed roleId)
func (_AccessManager *AccessManagerFilterer) ParseTargetFunctionRoleUpdated(log types.Log) (*AccessManagerTargetFunctionRoleUpdated, error) {
	event := new(AccessManagerTargetFunctionRoleUpdated)
	if err := _AccessManager.contract.UnpackLog(event, "TargetFunctionRoleUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// LPVaultMetaData contains all meta data concerning the LPVault contract.
var LPVaultMetaData = &bind.MetaData{
	ABI: "[{\"inputs\":[{\"internalType\":\"contractIERC20\",\"name\":\"asset_\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"authority_\",\"type\":\"address\"},{\"internalType\":\"string\",\"name\":\"name_\",\"type\":\"string\"},{\"internalType\":\"string\",\"name\":\"symbol_\",\"type\":\"string\"}],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"}],\"name\":\"allowance\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"approve\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"asset\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"authority\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"balanceOf\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"requestId\",\"type\":\"uint256\"}],\"name\":\"cancelRequest\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"shares\",\"type\":\"uint256\"}],\"name\":\"convertToAssets\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"}],\"name\":\"convertToShares\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"decimals\",\"outputs\":[{\"internalType\":\"uint8\",\"name\":\"\",\"type\":\"uint8\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"},{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"name\":\"deposit\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"pure\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"escrowedAssets\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"escrowedShares\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"requestId\",\"type\":\"uint256\"},{\"components\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint64\",\"name\":\"timestamp\",\"type\":\"uint64\"},{\"internalType\":\"bytes\",\"name\":\"signature\",\"type\":\"bytes\"}],\"internalType\":\"structIOracleVerifier.SignedPriceReport[]\",\"name\":\"reports\",\"type\":\"tuple[]\"}],\"name\":\"executeRequest\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"requestId\",\"type\":\"uint256\"}],\"name\":\"getRequest\",\"outputs\":[{\"components\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"internalType\":\"bool\",\"name\":\"isDeposit\",\"type\":\"bool\"},{\"internalType\":\"uint64\",\"name\":\"createdAt\",\"type\":\"uint64\"},{\"internalType\":\"uint128\",\"name\":\"amount\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"minOut\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"executionFee\",\"type\":\"uint128\"}],\"internalType\":\"structILPVault.LpRequest\",\"name\":\"\",\"type\":\"tuple\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"isConsumingScheduledOp\",\"outputs\":[{\"internalType\":\"bytes4\",\"name\":\"\",\"type\":\"bytes4\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"market\",\"outputs\":[{\"internalType\":\"contractIPerpsMarket\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"name\":\"maxDeposit\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"pure\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"name\":\"maxMint\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"pure\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"name\":\"maxRedeem\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"pure\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"name\":\"maxWithdraw\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"pure\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"},{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"name\":\"mint\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"pure\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"name\",\"outputs\":[{\"internalType\":\"string\",\"name\":\"\",\"type\":\"string\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"nextRequestId\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"}],\"name\":\"previewDeposit\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"shares\",\"type\":\"uint256\"}],\"name\":\"previewMint\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"shares\",\"type\":\"uint256\"}],\"name\":\"previewRedeem\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"}],\"name\":\"previewWithdraw\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"},{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"name\":\"redeem\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"pure\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"minShares\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"executionFee\",\"type\":\"uint256\"}],\"name\":\"requestDeposit\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"requestId\",\"type\":\"uint256\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"shares\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"minAssets\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"executionFee\",\"type\":\"uint256\"}],\"name\":\"requestRedeem\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"requestId\",\"type\":\"uint256\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"newAuthority\",\"type\":\"address\"}],\"name\":\"setAuthority\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"symbol\",\"outputs\":[{\"internalType\":\"string\",\"name\":\"\",\"type\":\"string\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"totalAssets\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"totalSupply\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"transfer\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"from\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"transferFrom\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"},{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"name\":\"withdraw\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"pure\",\"type\":\"function\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"Approval\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"address\",\"name\":\"authority\",\"type\":\"address\"}],\"name\":\"AuthorityUpdated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"sender\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"shares\",\"type\":\"uint256\"}],\"name\":\"Deposit\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"requestId\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"cancelledBy\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"bytes\",\"name\":\"reason\",\"type\":\"bytes\"}],\"name\":\"LpRequestCancelled\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"requestId\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"bool\",\"name\":\"isDeposit\",\"type\":\"bool\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amount\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"minOut\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"executionFee\",\"type\":\"uint256\"}],\"name\":\"LpRequestCreated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"requestId\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"keeper\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amountIn\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amountOut\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"}],\"name\":\"LpRequestExecuted\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"from\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"Transfer\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"sender\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"receiver\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"shares\",\"type\":\"uint256\"}],\"name\":\"Withdraw\",\"type\":\"event\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"authority\",\"type\":\"address\"}],\"name\":\"AccessManagedInvalidAuthority\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"uint32\",\"name\":\"delay\",\"type\":\"uint32\"}],\"name\":\"AccessManagedRequiredDelay\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"}],\"name\":\"AccessManagedUnauthorized\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"cancellableAt\",\"type\":\"uint256\"}],\"name\":\"CancelTooEarly\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"allowance\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"needed\",\"type\":\"uint256\"}],\"name\":\"ERC20InsufficientAllowance\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"sender\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"balance\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"needed\",\"type\":\"uint256\"}],\"name\":\"ERC20InsufficientBalance\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"approver\",\"type\":\"address\"}],\"name\":\"ERC20InvalidApprover\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"receiver\",\"type\":\"address\"}],\"name\":\"ERC20InvalidReceiver\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"sender\",\"type\":\"address\"}],\"name\":\"ERC20InvalidSender\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"}],\"name\":\"ERC20InvalidSpender\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"receiver\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"max\",\"type\":\"uint256\"}],\"name\":\"ERC4626ExceededMaxDeposit\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"receiver\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"shares\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"max\",\"type\":\"uint256\"}],\"name\":\"ERC4626ExceededMaxMint\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"shares\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"max\",\"type\":\"uint256\"}],\"name\":\"ERC4626ExceededMaxRedeem\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"max\",\"type\":\"uint256\"}],\"name\":\"ERC4626ExceededMaxWithdraw\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"EmptyRequest\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"fee\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"minFee\",\"type\":\"uint256\"}],\"name\":\"ExecutionFeeTooLow\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"ExecutionOutOfGas\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"MarketPaused\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"}],\"name\":\"NotRequestOwner\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"ReentrancyGuardReentrantCall\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint8\",\"name\":\"bits\",\"type\":\"uint8\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"SafeCastOverflowedUintDowncast\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"token\",\"type\":\"address\"}],\"name\":\"SafeERC20FailedOperation\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"amountOut\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"minOut\",\"type\":\"uint256\"}],\"name\":\"SlippageExceeded\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"SynchronousEntryDisabled\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"requestId\",\"type\":\"uint256\"}],\"name\":\"UnknownRequest\",\"type\":\"error\"}]",
}

// LPVaultABI is the input ABI used to generate the binding from.
// Deprecated: Use LPVaultMetaData.ABI instead.
var LPVaultABI = LPVaultMetaData.ABI

// LPVault is an auto generated Go binding around an Ethereum contract.
type LPVault struct {
	LPVaultCaller     // Read-only binding to the contract
	LPVaultTransactor // Write-only binding to the contract
	LPVaultFilterer   // Log filterer for contract events
}

// LPVaultCaller is an auto generated read-only Go binding around an Ethereum contract.
type LPVaultCaller struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// LPVaultTransactor is an auto generated write-only Go binding around an Ethereum contract.
type LPVaultTransactor struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// LPVaultFilterer is an auto generated log filtering Go binding around an Ethereum contract events.
type LPVaultFilterer struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// LPVaultSession is an auto generated Go binding around an Ethereum contract,
// with pre-set call and transact options.
type LPVaultSession struct {
	Contract     *LPVault          // Generic contract binding to set the session for
	CallOpts     bind.CallOpts     // Call options to use throughout this session
	TransactOpts bind.TransactOpts // Transaction auth options to use throughout this session
}

// LPVaultCallerSession is an auto generated read-only Go binding around an Ethereum contract,
// with pre-set call options.
type LPVaultCallerSession struct {
	Contract *LPVaultCaller // Generic contract caller binding to set the session for
	CallOpts bind.CallOpts  // Call options to use throughout this session
}

// LPVaultTransactorSession is an auto generated write-only Go binding around an Ethereum contract,
// with pre-set transact options.
type LPVaultTransactorSession struct {
	Contract     *LPVaultTransactor // Generic contract transactor binding to set the session for
	TransactOpts bind.TransactOpts  // Transaction auth options to use throughout this session
}

// LPVaultRaw is an auto generated low-level Go binding around an Ethereum contract.
type LPVaultRaw struct {
	Contract *LPVault // Generic contract binding to access the raw methods on
}

// LPVaultCallerRaw is an auto generated low-level read-only Go binding around an Ethereum contract.
type LPVaultCallerRaw struct {
	Contract *LPVaultCaller // Generic read-only contract binding to access the raw methods on
}

// LPVaultTransactorRaw is an auto generated low-level write-only Go binding around an Ethereum contract.
type LPVaultTransactorRaw struct {
	Contract *LPVaultTransactor // Generic write-only contract binding to access the raw methods on
}

// NewLPVault creates a new instance of LPVault, bound to a specific deployed contract.
func NewLPVault(address common.Address, backend bind.ContractBackend) (*LPVault, error) {
	contract, err := bindLPVault(address, backend, backend, backend)
	if err != nil {
		return nil, err
	}
	return &LPVault{LPVaultCaller: LPVaultCaller{contract: contract}, LPVaultTransactor: LPVaultTransactor{contract: contract}, LPVaultFilterer: LPVaultFilterer{contract: contract}}, nil
}

// NewLPVaultCaller creates a new read-only instance of LPVault, bound to a specific deployed contract.
func NewLPVaultCaller(address common.Address, caller bind.ContractCaller) (*LPVaultCaller, error) {
	contract, err := bindLPVault(address, caller, nil, nil)
	if err != nil {
		return nil, err
	}
	return &LPVaultCaller{contract: contract}, nil
}

// NewLPVaultTransactor creates a new write-only instance of LPVault, bound to a specific deployed contract.
func NewLPVaultTransactor(address common.Address, transactor bind.ContractTransactor) (*LPVaultTransactor, error) {
	contract, err := bindLPVault(address, nil, transactor, nil)
	if err != nil {
		return nil, err
	}
	return &LPVaultTransactor{contract: contract}, nil
}

// NewLPVaultFilterer creates a new log filterer instance of LPVault, bound to a specific deployed contract.
func NewLPVaultFilterer(address common.Address, filterer bind.ContractFilterer) (*LPVaultFilterer, error) {
	contract, err := bindLPVault(address, nil, nil, filterer)
	if err != nil {
		return nil, err
	}
	return &LPVaultFilterer{contract: contract}, nil
}

// bindLPVault binds a generic wrapper to an already deployed contract.
func bindLPVault(address common.Address, caller bind.ContractCaller, transactor bind.ContractTransactor, filterer bind.ContractFilterer) (*bind.BoundContract, error) {
	parsed, err := LPVaultMetaData.GetAbi()
	if err != nil {
		return nil, err
	}
	return bind.NewBoundContract(address, *parsed, caller, transactor, filterer), nil
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_LPVault *LPVaultRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _LPVault.Contract.LPVaultCaller.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_LPVault *LPVaultRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _LPVault.Contract.LPVaultTransactor.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_LPVault *LPVaultRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _LPVault.Contract.LPVaultTransactor.contract.Transact(opts, method, params...)
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_LPVault *LPVaultCallerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _LPVault.Contract.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_LPVault *LPVaultTransactorRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _LPVault.Contract.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_LPVault *LPVaultTransactorRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _LPVault.Contract.contract.Transact(opts, method, params...)
}

// Allowance is a free data retrieval call binding the contract method 0xdd62ed3e.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (_LPVault *LPVaultCaller) Allowance(opts *bind.CallOpts, owner common.Address, spender common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "allowance", owner, spender)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// Allowance is a free data retrieval call binding the contract method 0xdd62ed3e.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (_LPVault *LPVaultSession) Allowance(owner common.Address, spender common.Address) (*big.Int, error) {
	return _LPVault.Contract.Allowance(&_LPVault.CallOpts, owner, spender)
}

// Allowance is a free data retrieval call binding the contract method 0xdd62ed3e.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (_LPVault *LPVaultCallerSession) Allowance(owner common.Address, spender common.Address) (*big.Int, error) {
	return _LPVault.Contract.Allowance(&_LPVault.CallOpts, owner, spender)
}

// Asset is a free data retrieval call binding the contract method 0x38d52e0f.
//
// Solidity: function asset() view returns(address)
func (_LPVault *LPVaultCaller) Asset(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "asset")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Asset is a free data retrieval call binding the contract method 0x38d52e0f.
//
// Solidity: function asset() view returns(address)
func (_LPVault *LPVaultSession) Asset() (common.Address, error) {
	return _LPVault.Contract.Asset(&_LPVault.CallOpts)
}

// Asset is a free data retrieval call binding the contract method 0x38d52e0f.
//
// Solidity: function asset() view returns(address)
func (_LPVault *LPVaultCallerSession) Asset() (common.Address, error) {
	return _LPVault.Contract.Asset(&_LPVault.CallOpts)
}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_LPVault *LPVaultCaller) Authority(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "authority")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_LPVault *LPVaultSession) Authority() (common.Address, error) {
	return _LPVault.Contract.Authority(&_LPVault.CallOpts)
}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_LPVault *LPVaultCallerSession) Authority() (common.Address, error) {
	return _LPVault.Contract.Authority(&_LPVault.CallOpts)
}

// BalanceOf is a free data retrieval call binding the contract method 0x70a08231.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (_LPVault *LPVaultCaller) BalanceOf(opts *bind.CallOpts, account common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "balanceOf", account)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// BalanceOf is a free data retrieval call binding the contract method 0x70a08231.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (_LPVault *LPVaultSession) BalanceOf(account common.Address) (*big.Int, error) {
	return _LPVault.Contract.BalanceOf(&_LPVault.CallOpts, account)
}

// BalanceOf is a free data retrieval call binding the contract method 0x70a08231.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (_LPVault *LPVaultCallerSession) BalanceOf(account common.Address) (*big.Int, error) {
	return _LPVault.Contract.BalanceOf(&_LPVault.CallOpts, account)
}

// ConvertToAssets is a free data retrieval call binding the contract method 0x07a2d13a.
//
// Solidity: function convertToAssets(uint256 shares) view returns(uint256)
func (_LPVault *LPVaultCaller) ConvertToAssets(opts *bind.CallOpts, shares *big.Int) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "convertToAssets", shares)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// ConvertToAssets is a free data retrieval call binding the contract method 0x07a2d13a.
//
// Solidity: function convertToAssets(uint256 shares) view returns(uint256)
func (_LPVault *LPVaultSession) ConvertToAssets(shares *big.Int) (*big.Int, error) {
	return _LPVault.Contract.ConvertToAssets(&_LPVault.CallOpts, shares)
}

// ConvertToAssets is a free data retrieval call binding the contract method 0x07a2d13a.
//
// Solidity: function convertToAssets(uint256 shares) view returns(uint256)
func (_LPVault *LPVaultCallerSession) ConvertToAssets(shares *big.Int) (*big.Int, error) {
	return _LPVault.Contract.ConvertToAssets(&_LPVault.CallOpts, shares)
}

// ConvertToShares is a free data retrieval call binding the contract method 0xc6e6f592.
//
// Solidity: function convertToShares(uint256 assets) view returns(uint256)
func (_LPVault *LPVaultCaller) ConvertToShares(opts *bind.CallOpts, assets *big.Int) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "convertToShares", assets)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// ConvertToShares is a free data retrieval call binding the contract method 0xc6e6f592.
//
// Solidity: function convertToShares(uint256 assets) view returns(uint256)
func (_LPVault *LPVaultSession) ConvertToShares(assets *big.Int) (*big.Int, error) {
	return _LPVault.Contract.ConvertToShares(&_LPVault.CallOpts, assets)
}

// ConvertToShares is a free data retrieval call binding the contract method 0xc6e6f592.
//
// Solidity: function convertToShares(uint256 assets) view returns(uint256)
func (_LPVault *LPVaultCallerSession) ConvertToShares(assets *big.Int) (*big.Int, error) {
	return _LPVault.Contract.ConvertToShares(&_LPVault.CallOpts, assets)
}

// Decimals is a free data retrieval call binding the contract method 0x313ce567.
//
// Solidity: function decimals() view returns(uint8)
func (_LPVault *LPVaultCaller) Decimals(opts *bind.CallOpts) (uint8, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "decimals")

	if err != nil {
		return *new(uint8), err
	}

	out0 := *abi.ConvertType(out[0], new(uint8)).(*uint8)

	return out0, err

}

// Decimals is a free data retrieval call binding the contract method 0x313ce567.
//
// Solidity: function decimals() view returns(uint8)
func (_LPVault *LPVaultSession) Decimals() (uint8, error) {
	return _LPVault.Contract.Decimals(&_LPVault.CallOpts)
}

// Decimals is a free data retrieval call binding the contract method 0x313ce567.
//
// Solidity: function decimals() view returns(uint8)
func (_LPVault *LPVaultCallerSession) Decimals() (uint8, error) {
	return _LPVault.Contract.Decimals(&_LPVault.CallOpts)
}

// Deposit is a free data retrieval call binding the contract method 0x6e553f65.
//
// Solidity: function deposit(uint256 , address ) pure returns(uint256)
func (_LPVault *LPVaultCaller) Deposit(opts *bind.CallOpts, arg0 *big.Int, arg1 common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "deposit", arg0, arg1)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// Deposit is a free data retrieval call binding the contract method 0x6e553f65.
//
// Solidity: function deposit(uint256 , address ) pure returns(uint256)
func (_LPVault *LPVaultSession) Deposit(arg0 *big.Int, arg1 common.Address) (*big.Int, error) {
	return _LPVault.Contract.Deposit(&_LPVault.CallOpts, arg0, arg1)
}

// Deposit is a free data retrieval call binding the contract method 0x6e553f65.
//
// Solidity: function deposit(uint256 , address ) pure returns(uint256)
func (_LPVault *LPVaultCallerSession) Deposit(arg0 *big.Int, arg1 common.Address) (*big.Int, error) {
	return _LPVault.Contract.Deposit(&_LPVault.CallOpts, arg0, arg1)
}

// EscrowedAssets is a free data retrieval call binding the contract method 0xc3cb99cb.
//
// Solidity: function escrowedAssets() view returns(uint256)
func (_LPVault *LPVaultCaller) EscrowedAssets(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "escrowedAssets")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// EscrowedAssets is a free data retrieval call binding the contract method 0xc3cb99cb.
//
// Solidity: function escrowedAssets() view returns(uint256)
func (_LPVault *LPVaultSession) EscrowedAssets() (*big.Int, error) {
	return _LPVault.Contract.EscrowedAssets(&_LPVault.CallOpts)
}

// EscrowedAssets is a free data retrieval call binding the contract method 0xc3cb99cb.
//
// Solidity: function escrowedAssets() view returns(uint256)
func (_LPVault *LPVaultCallerSession) EscrowedAssets() (*big.Int, error) {
	return _LPVault.Contract.EscrowedAssets(&_LPVault.CallOpts)
}

// EscrowedShares is a free data retrieval call binding the contract method 0x704743ee.
//
// Solidity: function escrowedShares() view returns(uint256)
func (_LPVault *LPVaultCaller) EscrowedShares(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "escrowedShares")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// EscrowedShares is a free data retrieval call binding the contract method 0x704743ee.
//
// Solidity: function escrowedShares() view returns(uint256)
func (_LPVault *LPVaultSession) EscrowedShares() (*big.Int, error) {
	return _LPVault.Contract.EscrowedShares(&_LPVault.CallOpts)
}

// EscrowedShares is a free data retrieval call binding the contract method 0x704743ee.
//
// Solidity: function escrowedShares() view returns(uint256)
func (_LPVault *LPVaultCallerSession) EscrowedShares() (*big.Int, error) {
	return _LPVault.Contract.EscrowedShares(&_LPVault.CallOpts)
}

// GetRequest is a free data retrieval call binding the contract method 0xc58343ef.
//
// Solidity: function getRequest(uint256 requestId) view returns((address,bool,uint64,uint128,uint128,uint128))
func (_LPVault *LPVaultCaller) GetRequest(opts *bind.CallOpts, requestId *big.Int) (ILPVaultLpRequest, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "getRequest", requestId)

	if err != nil {
		return *new(ILPVaultLpRequest), err
	}

	out0 := *abi.ConvertType(out[0], new(ILPVaultLpRequest)).(*ILPVaultLpRequest)

	return out0, err

}

// GetRequest is a free data retrieval call binding the contract method 0xc58343ef.
//
// Solidity: function getRequest(uint256 requestId) view returns((address,bool,uint64,uint128,uint128,uint128))
func (_LPVault *LPVaultSession) GetRequest(requestId *big.Int) (ILPVaultLpRequest, error) {
	return _LPVault.Contract.GetRequest(&_LPVault.CallOpts, requestId)
}

// GetRequest is a free data retrieval call binding the contract method 0xc58343ef.
//
// Solidity: function getRequest(uint256 requestId) view returns((address,bool,uint64,uint128,uint128,uint128))
func (_LPVault *LPVaultCallerSession) GetRequest(requestId *big.Int) (ILPVaultLpRequest, error) {
	return _LPVault.Contract.GetRequest(&_LPVault.CallOpts, requestId)
}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_LPVault *LPVaultCaller) IsConsumingScheduledOp(opts *bind.CallOpts) ([4]byte, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "isConsumingScheduledOp")

	if err != nil {
		return *new([4]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([4]byte)).(*[4]byte)

	return out0, err

}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_LPVault *LPVaultSession) IsConsumingScheduledOp() ([4]byte, error) {
	return _LPVault.Contract.IsConsumingScheduledOp(&_LPVault.CallOpts)
}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_LPVault *LPVaultCallerSession) IsConsumingScheduledOp() ([4]byte, error) {
	return _LPVault.Contract.IsConsumingScheduledOp(&_LPVault.CallOpts)
}

// Market is a free data retrieval call binding the contract method 0x80f55605.
//
// Solidity: function market() view returns(address)
func (_LPVault *LPVaultCaller) Market(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "market")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Market is a free data retrieval call binding the contract method 0x80f55605.
//
// Solidity: function market() view returns(address)
func (_LPVault *LPVaultSession) Market() (common.Address, error) {
	return _LPVault.Contract.Market(&_LPVault.CallOpts)
}

// Market is a free data retrieval call binding the contract method 0x80f55605.
//
// Solidity: function market() view returns(address)
func (_LPVault *LPVaultCallerSession) Market() (common.Address, error) {
	return _LPVault.Contract.Market(&_LPVault.CallOpts)
}

// MaxDeposit is a free data retrieval call binding the contract method 0x402d267d.
//
// Solidity: function maxDeposit(address ) pure returns(uint256)
func (_LPVault *LPVaultCaller) MaxDeposit(opts *bind.CallOpts, arg0 common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "maxDeposit", arg0)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// MaxDeposit is a free data retrieval call binding the contract method 0x402d267d.
//
// Solidity: function maxDeposit(address ) pure returns(uint256)
func (_LPVault *LPVaultSession) MaxDeposit(arg0 common.Address) (*big.Int, error) {
	return _LPVault.Contract.MaxDeposit(&_LPVault.CallOpts, arg0)
}

// MaxDeposit is a free data retrieval call binding the contract method 0x402d267d.
//
// Solidity: function maxDeposit(address ) pure returns(uint256)
func (_LPVault *LPVaultCallerSession) MaxDeposit(arg0 common.Address) (*big.Int, error) {
	return _LPVault.Contract.MaxDeposit(&_LPVault.CallOpts, arg0)
}

// MaxMint is a free data retrieval call binding the contract method 0xc63d75b6.
//
// Solidity: function maxMint(address ) pure returns(uint256)
func (_LPVault *LPVaultCaller) MaxMint(opts *bind.CallOpts, arg0 common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "maxMint", arg0)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// MaxMint is a free data retrieval call binding the contract method 0xc63d75b6.
//
// Solidity: function maxMint(address ) pure returns(uint256)
func (_LPVault *LPVaultSession) MaxMint(arg0 common.Address) (*big.Int, error) {
	return _LPVault.Contract.MaxMint(&_LPVault.CallOpts, arg0)
}

// MaxMint is a free data retrieval call binding the contract method 0xc63d75b6.
//
// Solidity: function maxMint(address ) pure returns(uint256)
func (_LPVault *LPVaultCallerSession) MaxMint(arg0 common.Address) (*big.Int, error) {
	return _LPVault.Contract.MaxMint(&_LPVault.CallOpts, arg0)
}

// MaxRedeem is a free data retrieval call binding the contract method 0xd905777e.
//
// Solidity: function maxRedeem(address ) pure returns(uint256)
func (_LPVault *LPVaultCaller) MaxRedeem(opts *bind.CallOpts, arg0 common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "maxRedeem", arg0)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// MaxRedeem is a free data retrieval call binding the contract method 0xd905777e.
//
// Solidity: function maxRedeem(address ) pure returns(uint256)
func (_LPVault *LPVaultSession) MaxRedeem(arg0 common.Address) (*big.Int, error) {
	return _LPVault.Contract.MaxRedeem(&_LPVault.CallOpts, arg0)
}

// MaxRedeem is a free data retrieval call binding the contract method 0xd905777e.
//
// Solidity: function maxRedeem(address ) pure returns(uint256)
func (_LPVault *LPVaultCallerSession) MaxRedeem(arg0 common.Address) (*big.Int, error) {
	return _LPVault.Contract.MaxRedeem(&_LPVault.CallOpts, arg0)
}

// MaxWithdraw is a free data retrieval call binding the contract method 0xce96cb77.
//
// Solidity: function maxWithdraw(address ) pure returns(uint256)
func (_LPVault *LPVaultCaller) MaxWithdraw(opts *bind.CallOpts, arg0 common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "maxWithdraw", arg0)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// MaxWithdraw is a free data retrieval call binding the contract method 0xce96cb77.
//
// Solidity: function maxWithdraw(address ) pure returns(uint256)
func (_LPVault *LPVaultSession) MaxWithdraw(arg0 common.Address) (*big.Int, error) {
	return _LPVault.Contract.MaxWithdraw(&_LPVault.CallOpts, arg0)
}

// MaxWithdraw is a free data retrieval call binding the contract method 0xce96cb77.
//
// Solidity: function maxWithdraw(address ) pure returns(uint256)
func (_LPVault *LPVaultCallerSession) MaxWithdraw(arg0 common.Address) (*big.Int, error) {
	return _LPVault.Contract.MaxWithdraw(&_LPVault.CallOpts, arg0)
}

// Mint is a free data retrieval call binding the contract method 0x94bf804d.
//
// Solidity: function mint(uint256 , address ) pure returns(uint256)
func (_LPVault *LPVaultCaller) Mint(opts *bind.CallOpts, arg0 *big.Int, arg1 common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "mint", arg0, arg1)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// Mint is a free data retrieval call binding the contract method 0x94bf804d.
//
// Solidity: function mint(uint256 , address ) pure returns(uint256)
func (_LPVault *LPVaultSession) Mint(arg0 *big.Int, arg1 common.Address) (*big.Int, error) {
	return _LPVault.Contract.Mint(&_LPVault.CallOpts, arg0, arg1)
}

// Mint is a free data retrieval call binding the contract method 0x94bf804d.
//
// Solidity: function mint(uint256 , address ) pure returns(uint256)
func (_LPVault *LPVaultCallerSession) Mint(arg0 *big.Int, arg1 common.Address) (*big.Int, error) {
	return _LPVault.Contract.Mint(&_LPVault.CallOpts, arg0, arg1)
}

// Name is a free data retrieval call binding the contract method 0x06fdde03.
//
// Solidity: function name() view returns(string)
func (_LPVault *LPVaultCaller) Name(opts *bind.CallOpts) (string, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "name")

	if err != nil {
		return *new(string), err
	}

	out0 := *abi.ConvertType(out[0], new(string)).(*string)

	return out0, err

}

// Name is a free data retrieval call binding the contract method 0x06fdde03.
//
// Solidity: function name() view returns(string)
func (_LPVault *LPVaultSession) Name() (string, error) {
	return _LPVault.Contract.Name(&_LPVault.CallOpts)
}

// Name is a free data retrieval call binding the contract method 0x06fdde03.
//
// Solidity: function name() view returns(string)
func (_LPVault *LPVaultCallerSession) Name() (string, error) {
	return _LPVault.Contract.Name(&_LPVault.CallOpts)
}

// NextRequestId is a free data retrieval call binding the contract method 0x6a84a985.
//
// Solidity: function nextRequestId() view returns(uint256)
func (_LPVault *LPVaultCaller) NextRequestId(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "nextRequestId")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// NextRequestId is a free data retrieval call binding the contract method 0x6a84a985.
//
// Solidity: function nextRequestId() view returns(uint256)
func (_LPVault *LPVaultSession) NextRequestId() (*big.Int, error) {
	return _LPVault.Contract.NextRequestId(&_LPVault.CallOpts)
}

// NextRequestId is a free data retrieval call binding the contract method 0x6a84a985.
//
// Solidity: function nextRequestId() view returns(uint256)
func (_LPVault *LPVaultCallerSession) NextRequestId() (*big.Int, error) {
	return _LPVault.Contract.NextRequestId(&_LPVault.CallOpts)
}

// PreviewDeposit is a free data retrieval call binding the contract method 0xef8b30f7.
//
// Solidity: function previewDeposit(uint256 assets) view returns(uint256)
func (_LPVault *LPVaultCaller) PreviewDeposit(opts *bind.CallOpts, assets *big.Int) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "previewDeposit", assets)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// PreviewDeposit is a free data retrieval call binding the contract method 0xef8b30f7.
//
// Solidity: function previewDeposit(uint256 assets) view returns(uint256)
func (_LPVault *LPVaultSession) PreviewDeposit(assets *big.Int) (*big.Int, error) {
	return _LPVault.Contract.PreviewDeposit(&_LPVault.CallOpts, assets)
}

// PreviewDeposit is a free data retrieval call binding the contract method 0xef8b30f7.
//
// Solidity: function previewDeposit(uint256 assets) view returns(uint256)
func (_LPVault *LPVaultCallerSession) PreviewDeposit(assets *big.Int) (*big.Int, error) {
	return _LPVault.Contract.PreviewDeposit(&_LPVault.CallOpts, assets)
}

// PreviewMint is a free data retrieval call binding the contract method 0xb3d7f6b9.
//
// Solidity: function previewMint(uint256 shares) view returns(uint256)
func (_LPVault *LPVaultCaller) PreviewMint(opts *bind.CallOpts, shares *big.Int) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "previewMint", shares)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// PreviewMint is a free data retrieval call binding the contract method 0xb3d7f6b9.
//
// Solidity: function previewMint(uint256 shares) view returns(uint256)
func (_LPVault *LPVaultSession) PreviewMint(shares *big.Int) (*big.Int, error) {
	return _LPVault.Contract.PreviewMint(&_LPVault.CallOpts, shares)
}

// PreviewMint is a free data retrieval call binding the contract method 0xb3d7f6b9.
//
// Solidity: function previewMint(uint256 shares) view returns(uint256)
func (_LPVault *LPVaultCallerSession) PreviewMint(shares *big.Int) (*big.Int, error) {
	return _LPVault.Contract.PreviewMint(&_LPVault.CallOpts, shares)
}

// PreviewRedeem is a free data retrieval call binding the contract method 0x4cdad506.
//
// Solidity: function previewRedeem(uint256 shares) view returns(uint256)
func (_LPVault *LPVaultCaller) PreviewRedeem(opts *bind.CallOpts, shares *big.Int) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "previewRedeem", shares)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// PreviewRedeem is a free data retrieval call binding the contract method 0x4cdad506.
//
// Solidity: function previewRedeem(uint256 shares) view returns(uint256)
func (_LPVault *LPVaultSession) PreviewRedeem(shares *big.Int) (*big.Int, error) {
	return _LPVault.Contract.PreviewRedeem(&_LPVault.CallOpts, shares)
}

// PreviewRedeem is a free data retrieval call binding the contract method 0x4cdad506.
//
// Solidity: function previewRedeem(uint256 shares) view returns(uint256)
func (_LPVault *LPVaultCallerSession) PreviewRedeem(shares *big.Int) (*big.Int, error) {
	return _LPVault.Contract.PreviewRedeem(&_LPVault.CallOpts, shares)
}

// PreviewWithdraw is a free data retrieval call binding the contract method 0x0a28a477.
//
// Solidity: function previewWithdraw(uint256 assets) view returns(uint256)
func (_LPVault *LPVaultCaller) PreviewWithdraw(opts *bind.CallOpts, assets *big.Int) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "previewWithdraw", assets)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// PreviewWithdraw is a free data retrieval call binding the contract method 0x0a28a477.
//
// Solidity: function previewWithdraw(uint256 assets) view returns(uint256)
func (_LPVault *LPVaultSession) PreviewWithdraw(assets *big.Int) (*big.Int, error) {
	return _LPVault.Contract.PreviewWithdraw(&_LPVault.CallOpts, assets)
}

// PreviewWithdraw is a free data retrieval call binding the contract method 0x0a28a477.
//
// Solidity: function previewWithdraw(uint256 assets) view returns(uint256)
func (_LPVault *LPVaultCallerSession) PreviewWithdraw(assets *big.Int) (*big.Int, error) {
	return _LPVault.Contract.PreviewWithdraw(&_LPVault.CallOpts, assets)
}

// Redeem is a free data retrieval call binding the contract method 0xba087652.
//
// Solidity: function redeem(uint256 , address , address ) pure returns(uint256)
func (_LPVault *LPVaultCaller) Redeem(opts *bind.CallOpts, arg0 *big.Int, arg1 common.Address, arg2 common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "redeem", arg0, arg1, arg2)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// Redeem is a free data retrieval call binding the contract method 0xba087652.
//
// Solidity: function redeem(uint256 , address , address ) pure returns(uint256)
func (_LPVault *LPVaultSession) Redeem(arg0 *big.Int, arg1 common.Address, arg2 common.Address) (*big.Int, error) {
	return _LPVault.Contract.Redeem(&_LPVault.CallOpts, arg0, arg1, arg2)
}

// Redeem is a free data retrieval call binding the contract method 0xba087652.
//
// Solidity: function redeem(uint256 , address , address ) pure returns(uint256)
func (_LPVault *LPVaultCallerSession) Redeem(arg0 *big.Int, arg1 common.Address, arg2 common.Address) (*big.Int, error) {
	return _LPVault.Contract.Redeem(&_LPVault.CallOpts, arg0, arg1, arg2)
}

// Symbol is a free data retrieval call binding the contract method 0x95d89b41.
//
// Solidity: function symbol() view returns(string)
func (_LPVault *LPVaultCaller) Symbol(opts *bind.CallOpts) (string, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "symbol")

	if err != nil {
		return *new(string), err
	}

	out0 := *abi.ConvertType(out[0], new(string)).(*string)

	return out0, err

}

// Symbol is a free data retrieval call binding the contract method 0x95d89b41.
//
// Solidity: function symbol() view returns(string)
func (_LPVault *LPVaultSession) Symbol() (string, error) {
	return _LPVault.Contract.Symbol(&_LPVault.CallOpts)
}

// Symbol is a free data retrieval call binding the contract method 0x95d89b41.
//
// Solidity: function symbol() view returns(string)
func (_LPVault *LPVaultCallerSession) Symbol() (string, error) {
	return _LPVault.Contract.Symbol(&_LPVault.CallOpts)
}

// TotalAssets is a free data retrieval call binding the contract method 0x01e1d114.
//
// Solidity: function totalAssets() view returns(uint256)
func (_LPVault *LPVaultCaller) TotalAssets(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "totalAssets")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// TotalAssets is a free data retrieval call binding the contract method 0x01e1d114.
//
// Solidity: function totalAssets() view returns(uint256)
func (_LPVault *LPVaultSession) TotalAssets() (*big.Int, error) {
	return _LPVault.Contract.TotalAssets(&_LPVault.CallOpts)
}

// TotalAssets is a free data retrieval call binding the contract method 0x01e1d114.
//
// Solidity: function totalAssets() view returns(uint256)
func (_LPVault *LPVaultCallerSession) TotalAssets() (*big.Int, error) {
	return _LPVault.Contract.TotalAssets(&_LPVault.CallOpts)
}

// TotalSupply is a free data retrieval call binding the contract method 0x18160ddd.
//
// Solidity: function totalSupply() view returns(uint256)
func (_LPVault *LPVaultCaller) TotalSupply(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "totalSupply")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// TotalSupply is a free data retrieval call binding the contract method 0x18160ddd.
//
// Solidity: function totalSupply() view returns(uint256)
func (_LPVault *LPVaultSession) TotalSupply() (*big.Int, error) {
	return _LPVault.Contract.TotalSupply(&_LPVault.CallOpts)
}

// TotalSupply is a free data retrieval call binding the contract method 0x18160ddd.
//
// Solidity: function totalSupply() view returns(uint256)
func (_LPVault *LPVaultCallerSession) TotalSupply() (*big.Int, error) {
	return _LPVault.Contract.TotalSupply(&_LPVault.CallOpts)
}

// Withdraw is a free data retrieval call binding the contract method 0xb460af94.
//
// Solidity: function withdraw(uint256 , address , address ) pure returns(uint256)
func (_LPVault *LPVaultCaller) Withdraw(opts *bind.CallOpts, arg0 *big.Int, arg1 common.Address, arg2 common.Address) (*big.Int, error) {
	var out []interface{}
	err := _LPVault.contract.Call(opts, &out, "withdraw", arg0, arg1, arg2)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// Withdraw is a free data retrieval call binding the contract method 0xb460af94.
//
// Solidity: function withdraw(uint256 , address , address ) pure returns(uint256)
func (_LPVault *LPVaultSession) Withdraw(arg0 *big.Int, arg1 common.Address, arg2 common.Address) (*big.Int, error) {
	return _LPVault.Contract.Withdraw(&_LPVault.CallOpts, arg0, arg1, arg2)
}

// Withdraw is a free data retrieval call binding the contract method 0xb460af94.
//
// Solidity: function withdraw(uint256 , address , address ) pure returns(uint256)
func (_LPVault *LPVaultCallerSession) Withdraw(arg0 *big.Int, arg1 common.Address, arg2 common.Address) (*big.Int, error) {
	return _LPVault.Contract.Withdraw(&_LPVault.CallOpts, arg0, arg1, arg2)
}

// Approve is a paid mutator transaction binding the contract method 0x095ea7b3.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (_LPVault *LPVaultTransactor) Approve(opts *bind.TransactOpts, spender common.Address, value *big.Int) (*types.Transaction, error) {
	return _LPVault.contract.Transact(opts, "approve", spender, value)
}

// Approve is a paid mutator transaction binding the contract method 0x095ea7b3.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (_LPVault *LPVaultSession) Approve(spender common.Address, value *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.Approve(&_LPVault.TransactOpts, spender, value)
}

// Approve is a paid mutator transaction binding the contract method 0x095ea7b3.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (_LPVault *LPVaultTransactorSession) Approve(spender common.Address, value *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.Approve(&_LPVault.TransactOpts, spender, value)
}

// CancelRequest is a paid mutator transaction binding the contract method 0x3015394c.
//
// Solidity: function cancelRequest(uint256 requestId) returns()
func (_LPVault *LPVaultTransactor) CancelRequest(opts *bind.TransactOpts, requestId *big.Int) (*types.Transaction, error) {
	return _LPVault.contract.Transact(opts, "cancelRequest", requestId)
}

// CancelRequest is a paid mutator transaction binding the contract method 0x3015394c.
//
// Solidity: function cancelRequest(uint256 requestId) returns()
func (_LPVault *LPVaultSession) CancelRequest(requestId *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.CancelRequest(&_LPVault.TransactOpts, requestId)
}

// CancelRequest is a paid mutator transaction binding the contract method 0x3015394c.
//
// Solidity: function cancelRequest(uint256 requestId) returns()
func (_LPVault *LPVaultTransactorSession) CancelRequest(requestId *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.CancelRequest(&_LPVault.TransactOpts, requestId)
}

// ExecuteRequest is a paid mutator transaction binding the contract method 0xb7dce2d0.
//
// Solidity: function executeRequest(uint256 requestId, (address,uint256,uint64,bytes)[] reports) returns()
func (_LPVault *LPVaultTransactor) ExecuteRequest(opts *bind.TransactOpts, requestId *big.Int, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _LPVault.contract.Transact(opts, "executeRequest", requestId, reports)
}

// ExecuteRequest is a paid mutator transaction binding the contract method 0xb7dce2d0.
//
// Solidity: function executeRequest(uint256 requestId, (address,uint256,uint64,bytes)[] reports) returns()
func (_LPVault *LPVaultSession) ExecuteRequest(requestId *big.Int, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _LPVault.Contract.ExecuteRequest(&_LPVault.TransactOpts, requestId, reports)
}

// ExecuteRequest is a paid mutator transaction binding the contract method 0xb7dce2d0.
//
// Solidity: function executeRequest(uint256 requestId, (address,uint256,uint64,bytes)[] reports) returns()
func (_LPVault *LPVaultTransactorSession) ExecuteRequest(requestId *big.Int, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _LPVault.Contract.ExecuteRequest(&_LPVault.TransactOpts, requestId, reports)
}

// RequestDeposit is a paid mutator transaction binding the contract method 0x3e3cf254.
//
// Solidity: function requestDeposit(uint256 assets, uint256 minShares, uint256 executionFee) returns(uint256 requestId)
func (_LPVault *LPVaultTransactor) RequestDeposit(opts *bind.TransactOpts, assets *big.Int, minShares *big.Int, executionFee *big.Int) (*types.Transaction, error) {
	return _LPVault.contract.Transact(opts, "requestDeposit", assets, minShares, executionFee)
}

// RequestDeposit is a paid mutator transaction binding the contract method 0x3e3cf254.
//
// Solidity: function requestDeposit(uint256 assets, uint256 minShares, uint256 executionFee) returns(uint256 requestId)
func (_LPVault *LPVaultSession) RequestDeposit(assets *big.Int, minShares *big.Int, executionFee *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.RequestDeposit(&_LPVault.TransactOpts, assets, minShares, executionFee)
}

// RequestDeposit is a paid mutator transaction binding the contract method 0x3e3cf254.
//
// Solidity: function requestDeposit(uint256 assets, uint256 minShares, uint256 executionFee) returns(uint256 requestId)
func (_LPVault *LPVaultTransactorSession) RequestDeposit(assets *big.Int, minShares *big.Int, executionFee *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.RequestDeposit(&_LPVault.TransactOpts, assets, minShares, executionFee)
}

// RequestRedeem is a paid mutator transaction binding the contract method 0xaf4dbb4e.
//
// Solidity: function requestRedeem(uint256 shares, uint256 minAssets, uint256 executionFee) returns(uint256 requestId)
func (_LPVault *LPVaultTransactor) RequestRedeem(opts *bind.TransactOpts, shares *big.Int, minAssets *big.Int, executionFee *big.Int) (*types.Transaction, error) {
	return _LPVault.contract.Transact(opts, "requestRedeem", shares, minAssets, executionFee)
}

// RequestRedeem is a paid mutator transaction binding the contract method 0xaf4dbb4e.
//
// Solidity: function requestRedeem(uint256 shares, uint256 minAssets, uint256 executionFee) returns(uint256 requestId)
func (_LPVault *LPVaultSession) RequestRedeem(shares *big.Int, minAssets *big.Int, executionFee *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.RequestRedeem(&_LPVault.TransactOpts, shares, minAssets, executionFee)
}

// RequestRedeem is a paid mutator transaction binding the contract method 0xaf4dbb4e.
//
// Solidity: function requestRedeem(uint256 shares, uint256 minAssets, uint256 executionFee) returns(uint256 requestId)
func (_LPVault *LPVaultTransactorSession) RequestRedeem(shares *big.Int, minAssets *big.Int, executionFee *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.RequestRedeem(&_LPVault.TransactOpts, shares, minAssets, executionFee)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_LPVault *LPVaultTransactor) SetAuthority(opts *bind.TransactOpts, newAuthority common.Address) (*types.Transaction, error) {
	return _LPVault.contract.Transact(opts, "setAuthority", newAuthority)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_LPVault *LPVaultSession) SetAuthority(newAuthority common.Address) (*types.Transaction, error) {
	return _LPVault.Contract.SetAuthority(&_LPVault.TransactOpts, newAuthority)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_LPVault *LPVaultTransactorSession) SetAuthority(newAuthority common.Address) (*types.Transaction, error) {
	return _LPVault.Contract.SetAuthority(&_LPVault.TransactOpts, newAuthority)
}

// Transfer is a paid mutator transaction binding the contract method 0xa9059cbb.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (_LPVault *LPVaultTransactor) Transfer(opts *bind.TransactOpts, to common.Address, value *big.Int) (*types.Transaction, error) {
	return _LPVault.contract.Transact(opts, "transfer", to, value)
}

// Transfer is a paid mutator transaction binding the contract method 0xa9059cbb.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (_LPVault *LPVaultSession) Transfer(to common.Address, value *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.Transfer(&_LPVault.TransactOpts, to, value)
}

// Transfer is a paid mutator transaction binding the contract method 0xa9059cbb.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (_LPVault *LPVaultTransactorSession) Transfer(to common.Address, value *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.Transfer(&_LPVault.TransactOpts, to, value)
}

// TransferFrom is a paid mutator transaction binding the contract method 0x23b872dd.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (_LPVault *LPVaultTransactor) TransferFrom(opts *bind.TransactOpts, from common.Address, to common.Address, value *big.Int) (*types.Transaction, error) {
	return _LPVault.contract.Transact(opts, "transferFrom", from, to, value)
}

// TransferFrom is a paid mutator transaction binding the contract method 0x23b872dd.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (_LPVault *LPVaultSession) TransferFrom(from common.Address, to common.Address, value *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.TransferFrom(&_LPVault.TransactOpts, from, to, value)
}

// TransferFrom is a paid mutator transaction binding the contract method 0x23b872dd.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (_LPVault *LPVaultTransactorSession) TransferFrom(from common.Address, to common.Address, value *big.Int) (*types.Transaction, error) {
	return _LPVault.Contract.TransferFrom(&_LPVault.TransactOpts, from, to, value)
}

// LPVaultApprovalIterator is returned from FilterApproval and is used to iterate over the raw logs and unpacked data for Approval events raised by the LPVault contract.
type LPVaultApprovalIterator struct {
	Event *LPVaultApproval // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *LPVaultApprovalIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(LPVaultApproval)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(LPVaultApproval)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *LPVaultApprovalIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *LPVaultApprovalIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// LPVaultApproval represents a Approval event raised by the LPVault contract.
type LPVaultApproval struct {
	Owner   common.Address
	Spender common.Address
	Value   *big.Int
	Raw     types.Log // Blockchain specific contextual infos
}

// FilterApproval is a free log retrieval operation binding the contract event 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925.
//
// Solidity: event Approval(address indexed owner, address indexed spender, uint256 value)
func (_LPVault *LPVaultFilterer) FilterApproval(opts *bind.FilterOpts, owner []common.Address, spender []common.Address) (*LPVaultApprovalIterator, error) {

	var ownerRule []interface{}
	for _, ownerItem := range owner {
		ownerRule = append(ownerRule, ownerItem)
	}
	var spenderRule []interface{}
	for _, spenderItem := range spender {
		spenderRule = append(spenderRule, spenderItem)
	}

	logs, sub, err := _LPVault.contract.FilterLogs(opts, "Approval", ownerRule, spenderRule)
	if err != nil {
		return nil, err
	}
	return &LPVaultApprovalIterator{contract: _LPVault.contract, event: "Approval", logs: logs, sub: sub}, nil
}

// WatchApproval is a free log subscription operation binding the contract event 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925.
//
// Solidity: event Approval(address indexed owner, address indexed spender, uint256 value)
func (_LPVault *LPVaultFilterer) WatchApproval(opts *bind.WatchOpts, sink chan<- *LPVaultApproval, owner []common.Address, spender []common.Address) (event.Subscription, error) {

	var ownerRule []interface{}
	for _, ownerItem := range owner {
		ownerRule = append(ownerRule, ownerItem)
	}
	var spenderRule []interface{}
	for _, spenderItem := range spender {
		spenderRule = append(spenderRule, spenderItem)
	}

	logs, sub, err := _LPVault.contract.WatchLogs(opts, "Approval", ownerRule, spenderRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(LPVaultApproval)
				if err := _LPVault.contract.UnpackLog(event, "Approval", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseApproval is a log parse operation binding the contract event 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925.
//
// Solidity: event Approval(address indexed owner, address indexed spender, uint256 value)
func (_LPVault *LPVaultFilterer) ParseApproval(log types.Log) (*LPVaultApproval, error) {
	event := new(LPVaultApproval)
	if err := _LPVault.contract.UnpackLog(event, "Approval", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// LPVaultAuthorityUpdatedIterator is returned from FilterAuthorityUpdated and is used to iterate over the raw logs and unpacked data for AuthorityUpdated events raised by the LPVault contract.
type LPVaultAuthorityUpdatedIterator struct {
	Event *LPVaultAuthorityUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *LPVaultAuthorityUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(LPVaultAuthorityUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(LPVaultAuthorityUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *LPVaultAuthorityUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *LPVaultAuthorityUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// LPVaultAuthorityUpdated represents a AuthorityUpdated event raised by the LPVault contract.
type LPVaultAuthorityUpdated struct {
	Authority common.Address
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterAuthorityUpdated is a free log retrieval operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_LPVault *LPVaultFilterer) FilterAuthorityUpdated(opts *bind.FilterOpts) (*LPVaultAuthorityUpdatedIterator, error) {

	logs, sub, err := _LPVault.contract.FilterLogs(opts, "AuthorityUpdated")
	if err != nil {
		return nil, err
	}
	return &LPVaultAuthorityUpdatedIterator{contract: _LPVault.contract, event: "AuthorityUpdated", logs: logs, sub: sub}, nil
}

// WatchAuthorityUpdated is a free log subscription operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_LPVault *LPVaultFilterer) WatchAuthorityUpdated(opts *bind.WatchOpts, sink chan<- *LPVaultAuthorityUpdated) (event.Subscription, error) {

	logs, sub, err := _LPVault.contract.WatchLogs(opts, "AuthorityUpdated")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(LPVaultAuthorityUpdated)
				if err := _LPVault.contract.UnpackLog(event, "AuthorityUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseAuthorityUpdated is a log parse operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_LPVault *LPVaultFilterer) ParseAuthorityUpdated(log types.Log) (*LPVaultAuthorityUpdated, error) {
	event := new(LPVaultAuthorityUpdated)
	if err := _LPVault.contract.UnpackLog(event, "AuthorityUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// LPVaultDepositIterator is returned from FilterDeposit and is used to iterate over the raw logs and unpacked data for Deposit events raised by the LPVault contract.
type LPVaultDepositIterator struct {
	Event *LPVaultDeposit // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *LPVaultDepositIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(LPVaultDeposit)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(LPVaultDeposit)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *LPVaultDepositIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *LPVaultDepositIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// LPVaultDeposit represents a Deposit event raised by the LPVault contract.
type LPVaultDeposit struct {
	Sender common.Address
	Owner  common.Address
	Assets *big.Int
	Shares *big.Int
	Raw    types.Log // Blockchain specific contextual infos
}

// FilterDeposit is a free log retrieval operation binding the contract event 0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7.
//
// Solidity: event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)
func (_LPVault *LPVaultFilterer) FilterDeposit(opts *bind.FilterOpts, sender []common.Address, owner []common.Address) (*LPVaultDepositIterator, error) {

	var senderRule []interface{}
	for _, senderItem := range sender {
		senderRule = append(senderRule, senderItem)
	}
	var ownerRule []interface{}
	for _, ownerItem := range owner {
		ownerRule = append(ownerRule, ownerItem)
	}

	logs, sub, err := _LPVault.contract.FilterLogs(opts, "Deposit", senderRule, ownerRule)
	if err != nil {
		return nil, err
	}
	return &LPVaultDepositIterator{contract: _LPVault.contract, event: "Deposit", logs: logs, sub: sub}, nil
}

// WatchDeposit is a free log subscription operation binding the contract event 0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7.
//
// Solidity: event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)
func (_LPVault *LPVaultFilterer) WatchDeposit(opts *bind.WatchOpts, sink chan<- *LPVaultDeposit, sender []common.Address, owner []common.Address) (event.Subscription, error) {

	var senderRule []interface{}
	for _, senderItem := range sender {
		senderRule = append(senderRule, senderItem)
	}
	var ownerRule []interface{}
	for _, ownerItem := range owner {
		ownerRule = append(ownerRule, ownerItem)
	}

	logs, sub, err := _LPVault.contract.WatchLogs(opts, "Deposit", senderRule, ownerRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(LPVaultDeposit)
				if err := _LPVault.contract.UnpackLog(event, "Deposit", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseDeposit is a log parse operation binding the contract event 0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7.
//
// Solidity: event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)
func (_LPVault *LPVaultFilterer) ParseDeposit(log types.Log) (*LPVaultDeposit, error) {
	event := new(LPVaultDeposit)
	if err := _LPVault.contract.UnpackLog(event, "Deposit", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// LPVaultLpRequestCancelledIterator is returned from FilterLpRequestCancelled and is used to iterate over the raw logs and unpacked data for LpRequestCancelled events raised by the LPVault contract.
type LPVaultLpRequestCancelledIterator struct {
	Event *LPVaultLpRequestCancelled // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *LPVaultLpRequestCancelledIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(LPVaultLpRequestCancelled)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(LPVaultLpRequestCancelled)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *LPVaultLpRequestCancelledIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *LPVaultLpRequestCancelledIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// LPVaultLpRequestCancelled represents a LpRequestCancelled event raised by the LPVault contract.
type LPVaultLpRequestCancelled struct {
	RequestId   *big.Int
	CancelledBy common.Address
	Reason      []byte
	Raw         types.Log // Blockchain specific contextual infos
}

// FilterLpRequestCancelled is a free log retrieval operation binding the contract event 0x15ff1aa7a69432f2d25bfd1a930e7eab889b29daf52c2b8a3bd61a2ebfa8cbf2.
//
// Solidity: event LpRequestCancelled(uint256 indexed requestId, address indexed cancelledBy, bytes reason)
func (_LPVault *LPVaultFilterer) FilterLpRequestCancelled(opts *bind.FilterOpts, requestId []*big.Int, cancelledBy []common.Address) (*LPVaultLpRequestCancelledIterator, error) {

	var requestIdRule []interface{}
	for _, requestIdItem := range requestId {
		requestIdRule = append(requestIdRule, requestIdItem)
	}
	var cancelledByRule []interface{}
	for _, cancelledByItem := range cancelledBy {
		cancelledByRule = append(cancelledByRule, cancelledByItem)
	}

	logs, sub, err := _LPVault.contract.FilterLogs(opts, "LpRequestCancelled", requestIdRule, cancelledByRule)
	if err != nil {
		return nil, err
	}
	return &LPVaultLpRequestCancelledIterator{contract: _LPVault.contract, event: "LpRequestCancelled", logs: logs, sub: sub}, nil
}

// WatchLpRequestCancelled is a free log subscription operation binding the contract event 0x15ff1aa7a69432f2d25bfd1a930e7eab889b29daf52c2b8a3bd61a2ebfa8cbf2.
//
// Solidity: event LpRequestCancelled(uint256 indexed requestId, address indexed cancelledBy, bytes reason)
func (_LPVault *LPVaultFilterer) WatchLpRequestCancelled(opts *bind.WatchOpts, sink chan<- *LPVaultLpRequestCancelled, requestId []*big.Int, cancelledBy []common.Address) (event.Subscription, error) {

	var requestIdRule []interface{}
	for _, requestIdItem := range requestId {
		requestIdRule = append(requestIdRule, requestIdItem)
	}
	var cancelledByRule []interface{}
	for _, cancelledByItem := range cancelledBy {
		cancelledByRule = append(cancelledByRule, cancelledByItem)
	}

	logs, sub, err := _LPVault.contract.WatchLogs(opts, "LpRequestCancelled", requestIdRule, cancelledByRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(LPVaultLpRequestCancelled)
				if err := _LPVault.contract.UnpackLog(event, "LpRequestCancelled", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseLpRequestCancelled is a log parse operation binding the contract event 0x15ff1aa7a69432f2d25bfd1a930e7eab889b29daf52c2b8a3bd61a2ebfa8cbf2.
//
// Solidity: event LpRequestCancelled(uint256 indexed requestId, address indexed cancelledBy, bytes reason)
func (_LPVault *LPVaultFilterer) ParseLpRequestCancelled(log types.Log) (*LPVaultLpRequestCancelled, error) {
	event := new(LPVaultLpRequestCancelled)
	if err := _LPVault.contract.UnpackLog(event, "LpRequestCancelled", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// LPVaultLpRequestCreatedIterator is returned from FilterLpRequestCreated and is used to iterate over the raw logs and unpacked data for LpRequestCreated events raised by the LPVault contract.
type LPVaultLpRequestCreatedIterator struct {
	Event *LPVaultLpRequestCreated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *LPVaultLpRequestCreatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(LPVaultLpRequestCreated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(LPVaultLpRequestCreated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *LPVaultLpRequestCreatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *LPVaultLpRequestCreatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// LPVaultLpRequestCreated represents a LpRequestCreated event raised by the LPVault contract.
type LPVaultLpRequestCreated struct {
	RequestId    *big.Int
	Account      common.Address
	IsDeposit    bool
	Amount       *big.Int
	MinOut       *big.Int
	ExecutionFee *big.Int
	Raw          types.Log // Blockchain specific contextual infos
}

// FilterLpRequestCreated is a free log retrieval operation binding the contract event 0x26a2d26a9729caff89f29e26d0ca908bdfdbfdd45a767937528134b0f7568100.
//
// Solidity: event LpRequestCreated(uint256 indexed requestId, address indexed account, bool isDeposit, uint256 amount, uint256 minOut, uint256 executionFee)
func (_LPVault *LPVaultFilterer) FilterLpRequestCreated(opts *bind.FilterOpts, requestId []*big.Int, account []common.Address) (*LPVaultLpRequestCreatedIterator, error) {

	var requestIdRule []interface{}
	for _, requestIdItem := range requestId {
		requestIdRule = append(requestIdRule, requestIdItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}

	logs, sub, err := _LPVault.contract.FilterLogs(opts, "LpRequestCreated", requestIdRule, accountRule)
	if err != nil {
		return nil, err
	}
	return &LPVaultLpRequestCreatedIterator{contract: _LPVault.contract, event: "LpRequestCreated", logs: logs, sub: sub}, nil
}

// WatchLpRequestCreated is a free log subscription operation binding the contract event 0x26a2d26a9729caff89f29e26d0ca908bdfdbfdd45a767937528134b0f7568100.
//
// Solidity: event LpRequestCreated(uint256 indexed requestId, address indexed account, bool isDeposit, uint256 amount, uint256 minOut, uint256 executionFee)
func (_LPVault *LPVaultFilterer) WatchLpRequestCreated(opts *bind.WatchOpts, sink chan<- *LPVaultLpRequestCreated, requestId []*big.Int, account []common.Address) (event.Subscription, error) {

	var requestIdRule []interface{}
	for _, requestIdItem := range requestId {
		requestIdRule = append(requestIdRule, requestIdItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}

	logs, sub, err := _LPVault.contract.WatchLogs(opts, "LpRequestCreated", requestIdRule, accountRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(LPVaultLpRequestCreated)
				if err := _LPVault.contract.UnpackLog(event, "LpRequestCreated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseLpRequestCreated is a log parse operation binding the contract event 0x26a2d26a9729caff89f29e26d0ca908bdfdbfdd45a767937528134b0f7568100.
//
// Solidity: event LpRequestCreated(uint256 indexed requestId, address indexed account, bool isDeposit, uint256 amount, uint256 minOut, uint256 executionFee)
func (_LPVault *LPVaultFilterer) ParseLpRequestCreated(log types.Log) (*LPVaultLpRequestCreated, error) {
	event := new(LPVaultLpRequestCreated)
	if err := _LPVault.contract.UnpackLog(event, "LpRequestCreated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// LPVaultLpRequestExecutedIterator is returned from FilterLpRequestExecuted and is used to iterate over the raw logs and unpacked data for LpRequestExecuted events raised by the LPVault contract.
type LPVaultLpRequestExecutedIterator struct {
	Event *LPVaultLpRequestExecuted // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *LPVaultLpRequestExecutedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(LPVaultLpRequestExecuted)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(LPVaultLpRequestExecuted)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *LPVaultLpRequestExecutedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *LPVaultLpRequestExecutedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// LPVaultLpRequestExecuted represents a LpRequestExecuted event raised by the LPVault contract.
type LPVaultLpRequestExecuted struct {
	RequestId *big.Int
	Keeper    common.Address
	AmountIn  *big.Int
	AmountOut *big.Int
	Price     *big.Int
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterLpRequestExecuted is a free log retrieval operation binding the contract event 0x4719d71a3d6b1767f98078bd03019d4af3fc4e9d8b40a52783c193f69d47f457.
//
// Solidity: event LpRequestExecuted(uint256 indexed requestId, address indexed keeper, uint256 amountIn, uint256 amountOut, uint256 price)
func (_LPVault *LPVaultFilterer) FilterLpRequestExecuted(opts *bind.FilterOpts, requestId []*big.Int, keeper []common.Address) (*LPVaultLpRequestExecutedIterator, error) {

	var requestIdRule []interface{}
	for _, requestIdItem := range requestId {
		requestIdRule = append(requestIdRule, requestIdItem)
	}
	var keeperRule []interface{}
	for _, keeperItem := range keeper {
		keeperRule = append(keeperRule, keeperItem)
	}

	logs, sub, err := _LPVault.contract.FilterLogs(opts, "LpRequestExecuted", requestIdRule, keeperRule)
	if err != nil {
		return nil, err
	}
	return &LPVaultLpRequestExecutedIterator{contract: _LPVault.contract, event: "LpRequestExecuted", logs: logs, sub: sub}, nil
}

// WatchLpRequestExecuted is a free log subscription operation binding the contract event 0x4719d71a3d6b1767f98078bd03019d4af3fc4e9d8b40a52783c193f69d47f457.
//
// Solidity: event LpRequestExecuted(uint256 indexed requestId, address indexed keeper, uint256 amountIn, uint256 amountOut, uint256 price)
func (_LPVault *LPVaultFilterer) WatchLpRequestExecuted(opts *bind.WatchOpts, sink chan<- *LPVaultLpRequestExecuted, requestId []*big.Int, keeper []common.Address) (event.Subscription, error) {

	var requestIdRule []interface{}
	for _, requestIdItem := range requestId {
		requestIdRule = append(requestIdRule, requestIdItem)
	}
	var keeperRule []interface{}
	for _, keeperItem := range keeper {
		keeperRule = append(keeperRule, keeperItem)
	}

	logs, sub, err := _LPVault.contract.WatchLogs(opts, "LpRequestExecuted", requestIdRule, keeperRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(LPVaultLpRequestExecuted)
				if err := _LPVault.contract.UnpackLog(event, "LpRequestExecuted", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseLpRequestExecuted is a log parse operation binding the contract event 0x4719d71a3d6b1767f98078bd03019d4af3fc4e9d8b40a52783c193f69d47f457.
//
// Solidity: event LpRequestExecuted(uint256 indexed requestId, address indexed keeper, uint256 amountIn, uint256 amountOut, uint256 price)
func (_LPVault *LPVaultFilterer) ParseLpRequestExecuted(log types.Log) (*LPVaultLpRequestExecuted, error) {
	event := new(LPVaultLpRequestExecuted)
	if err := _LPVault.contract.UnpackLog(event, "LpRequestExecuted", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// LPVaultTransferIterator is returned from FilterTransfer and is used to iterate over the raw logs and unpacked data for Transfer events raised by the LPVault contract.
type LPVaultTransferIterator struct {
	Event *LPVaultTransfer // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *LPVaultTransferIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(LPVaultTransfer)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(LPVaultTransfer)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *LPVaultTransferIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *LPVaultTransferIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// LPVaultTransfer represents a Transfer event raised by the LPVault contract.
type LPVaultTransfer struct {
	From  common.Address
	To    common.Address
	Value *big.Int
	Raw   types.Log // Blockchain specific contextual infos
}

// FilterTransfer is a free log retrieval operation binding the contract event 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef.
//
// Solidity: event Transfer(address indexed from, address indexed to, uint256 value)
func (_LPVault *LPVaultFilterer) FilterTransfer(opts *bind.FilterOpts, from []common.Address, to []common.Address) (*LPVaultTransferIterator, error) {

	var fromRule []interface{}
	for _, fromItem := range from {
		fromRule = append(fromRule, fromItem)
	}
	var toRule []interface{}
	for _, toItem := range to {
		toRule = append(toRule, toItem)
	}

	logs, sub, err := _LPVault.contract.FilterLogs(opts, "Transfer", fromRule, toRule)
	if err != nil {
		return nil, err
	}
	return &LPVaultTransferIterator{contract: _LPVault.contract, event: "Transfer", logs: logs, sub: sub}, nil
}

// WatchTransfer is a free log subscription operation binding the contract event 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef.
//
// Solidity: event Transfer(address indexed from, address indexed to, uint256 value)
func (_LPVault *LPVaultFilterer) WatchTransfer(opts *bind.WatchOpts, sink chan<- *LPVaultTransfer, from []common.Address, to []common.Address) (event.Subscription, error) {

	var fromRule []interface{}
	for _, fromItem := range from {
		fromRule = append(fromRule, fromItem)
	}
	var toRule []interface{}
	for _, toItem := range to {
		toRule = append(toRule, toItem)
	}

	logs, sub, err := _LPVault.contract.WatchLogs(opts, "Transfer", fromRule, toRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(LPVaultTransfer)
				if err := _LPVault.contract.UnpackLog(event, "Transfer", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseTransfer is a log parse operation binding the contract event 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef.
//
// Solidity: event Transfer(address indexed from, address indexed to, uint256 value)
func (_LPVault *LPVaultFilterer) ParseTransfer(log types.Log) (*LPVaultTransfer, error) {
	event := new(LPVaultTransfer)
	if err := _LPVault.contract.UnpackLog(event, "Transfer", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// LPVaultWithdrawIterator is returned from FilterWithdraw and is used to iterate over the raw logs and unpacked data for Withdraw events raised by the LPVault contract.
type LPVaultWithdrawIterator struct {
	Event *LPVaultWithdraw // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *LPVaultWithdrawIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(LPVaultWithdraw)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(LPVaultWithdraw)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *LPVaultWithdrawIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *LPVaultWithdrawIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// LPVaultWithdraw represents a Withdraw event raised by the LPVault contract.
type LPVaultWithdraw struct {
	Sender   common.Address
	Receiver common.Address
	Owner    common.Address
	Assets   *big.Int
	Shares   *big.Int
	Raw      types.Log // Blockchain specific contextual infos
}

// FilterWithdraw is a free log retrieval operation binding the contract event 0xfbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db.
//
// Solidity: event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)
func (_LPVault *LPVaultFilterer) FilterWithdraw(opts *bind.FilterOpts, sender []common.Address, receiver []common.Address, owner []common.Address) (*LPVaultWithdrawIterator, error) {

	var senderRule []interface{}
	for _, senderItem := range sender {
		senderRule = append(senderRule, senderItem)
	}
	var receiverRule []interface{}
	for _, receiverItem := range receiver {
		receiverRule = append(receiverRule, receiverItem)
	}
	var ownerRule []interface{}
	for _, ownerItem := range owner {
		ownerRule = append(ownerRule, ownerItem)
	}

	logs, sub, err := _LPVault.contract.FilterLogs(opts, "Withdraw", senderRule, receiverRule, ownerRule)
	if err != nil {
		return nil, err
	}
	return &LPVaultWithdrawIterator{contract: _LPVault.contract, event: "Withdraw", logs: logs, sub: sub}, nil
}

// WatchWithdraw is a free log subscription operation binding the contract event 0xfbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db.
//
// Solidity: event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)
func (_LPVault *LPVaultFilterer) WatchWithdraw(opts *bind.WatchOpts, sink chan<- *LPVaultWithdraw, sender []common.Address, receiver []common.Address, owner []common.Address) (event.Subscription, error) {

	var senderRule []interface{}
	for _, senderItem := range sender {
		senderRule = append(senderRule, senderItem)
	}
	var receiverRule []interface{}
	for _, receiverItem := range receiver {
		receiverRule = append(receiverRule, receiverItem)
	}
	var ownerRule []interface{}
	for _, ownerItem := range owner {
		ownerRule = append(ownerRule, ownerItem)
	}

	logs, sub, err := _LPVault.contract.WatchLogs(opts, "Withdraw", senderRule, receiverRule, ownerRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(LPVaultWithdraw)
				if err := _LPVault.contract.UnpackLog(event, "Withdraw", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseWithdraw is a log parse operation binding the contract event 0xfbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db.
//
// Solidity: event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)
func (_LPVault *LPVaultFilterer) ParseWithdraw(log types.Log) (*LPVaultWithdraw, error) {
	event := new(LPVaultWithdraw)
	if err := _LPVault.contract.UnpackLog(event, "Withdraw", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// MockERC1271SignerMetaData contains all meta data concerning the MockERC1271Signer contract.
var MockERC1271SignerMetaData = &bind.MetaData{
	ABI: "[{\"inputs\":[{\"internalType\":\"address\",\"name\":\"owner_\",\"type\":\"address\"}],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"hash\",\"type\":\"bytes32\"},{\"internalType\":\"bytes\",\"name\":\"signature\",\"type\":\"bytes\"}],\"name\":\"isValidSignature\",\"outputs\":[{\"internalType\":\"bytes4\",\"name\":\"\",\"type\":\"bytes4\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"owner\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"}]",
	Bin: "0x60a0604052348015600e575f5ffd5b5060405161037e38038061037e833981016040819052602b91603b565b6001600160a01b03166080526066565b5f60208284031215604a575f5ffd5b81516001600160a01b0381168114605f575f5ffd5b9392505050565b6080516102fa6100845f395f8181606e015261010d01526102fa5ff3fe608060405234801561000f575f5ffd5b5060043610610034575f3560e01c80631626ba7e146100385780638da5cb5b14610069575b5f5ffd5b61004b61004636600461026f565b6100a8565b6040516001600160e01b031990911681526020015b60405180910390f35b6100907f000000000000000000000000000000000000000000000000000000000000000081565b6040516001600160a01b039091168152602001610060565b5f5f5f6100ea8686868080601f0160208091040260200160405190810160405280939291908181526020018383808284375f9201919091525061015e92505050565b5090925090505f816003811115610103576101036102e6565b14801561014157507f00000000000000000000000000000000000000000000000000000000000000006001600160a01b0316826001600160a01b0316145b61014b575f610154565b630b135d3f60e11b5b9695505050505050565b5f5f5f8351604103610195576020840151604085015160608601515f1a610187888285856101a7565b9550955095505050506101a0565b505081515f91506002905b9250925092565b5f80807f7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a08411156101e057505f91506003905082610265565b604080515f808252602082018084528a905260ff891692820192909252606081018790526080810186905260019060a0016020604051602081039080840390855afa158015610231573d5f5f3e3d5ffd5b5050604051601f1901519150506001600160a01b03811661025c57505f925060019150829050610265565b92505f91508190505b9450945094915050565b5f5f5f60408486031215610281575f5ffd5b83359250602084013567ffffffffffffffff81111561029e575f5ffd5b8401601f810186136102ae575f5ffd5b803567ffffffffffffffff8111156102c4575f5ffd5b8660208284010111156102d5575f5ffd5b939660209190910195509293505050565b634e487b7160e01b5f52602160045260245ffd",
}

// MockERC1271SignerABI is the input ABI used to generate the binding from.
// Deprecated: Use MockERC1271SignerMetaData.ABI instead.
var MockERC1271SignerABI = MockERC1271SignerMetaData.ABI

// MockERC1271SignerBin is the compiled bytecode used for deploying new contracts.
// Deprecated: Use MockERC1271SignerMetaData.Bin instead.
var MockERC1271SignerBin = MockERC1271SignerMetaData.Bin

// DeployMockERC1271Signer deploys a new Ethereum contract, binding an instance of MockERC1271Signer to it.
func DeployMockERC1271Signer(auth *bind.TransactOpts, backend bind.ContractBackend, owner_ common.Address) (common.Address, *types.Transaction, *MockERC1271Signer, error) {
	parsed, err := MockERC1271SignerMetaData.GetAbi()
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	if parsed == nil {
		return common.Address{}, nil, nil, errors.New("GetABI returned nil")
	}

	address, tx, contract, err := bind.DeployContract(auth, *parsed, common.FromHex(MockERC1271SignerBin), backend, owner_)
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	return address, tx, &MockERC1271Signer{MockERC1271SignerCaller: MockERC1271SignerCaller{contract: contract}, MockERC1271SignerTransactor: MockERC1271SignerTransactor{contract: contract}, MockERC1271SignerFilterer: MockERC1271SignerFilterer{contract: contract}}, nil
}

// MockERC1271Signer is an auto generated Go binding around an Ethereum contract.
type MockERC1271Signer struct {
	MockERC1271SignerCaller     // Read-only binding to the contract
	MockERC1271SignerTransactor // Write-only binding to the contract
	MockERC1271SignerFilterer   // Log filterer for contract events
}

// MockERC1271SignerCaller is an auto generated read-only Go binding around an Ethereum contract.
type MockERC1271SignerCaller struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// MockERC1271SignerTransactor is an auto generated write-only Go binding around an Ethereum contract.
type MockERC1271SignerTransactor struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// MockERC1271SignerFilterer is an auto generated log filtering Go binding around an Ethereum contract events.
type MockERC1271SignerFilterer struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// MockERC1271SignerSession is an auto generated Go binding around an Ethereum contract,
// with pre-set call and transact options.
type MockERC1271SignerSession struct {
	Contract     *MockERC1271Signer // Generic contract binding to set the session for
	CallOpts     bind.CallOpts      // Call options to use throughout this session
	TransactOpts bind.TransactOpts  // Transaction auth options to use throughout this session
}

// MockERC1271SignerCallerSession is an auto generated read-only Go binding around an Ethereum contract,
// with pre-set call options.
type MockERC1271SignerCallerSession struct {
	Contract *MockERC1271SignerCaller // Generic contract caller binding to set the session for
	CallOpts bind.CallOpts            // Call options to use throughout this session
}

// MockERC1271SignerTransactorSession is an auto generated write-only Go binding around an Ethereum contract,
// with pre-set transact options.
type MockERC1271SignerTransactorSession struct {
	Contract     *MockERC1271SignerTransactor // Generic contract transactor binding to set the session for
	TransactOpts bind.TransactOpts            // Transaction auth options to use throughout this session
}

// MockERC1271SignerRaw is an auto generated low-level Go binding around an Ethereum contract.
type MockERC1271SignerRaw struct {
	Contract *MockERC1271Signer // Generic contract binding to access the raw methods on
}

// MockERC1271SignerCallerRaw is an auto generated low-level read-only Go binding around an Ethereum contract.
type MockERC1271SignerCallerRaw struct {
	Contract *MockERC1271SignerCaller // Generic read-only contract binding to access the raw methods on
}

// MockERC1271SignerTransactorRaw is an auto generated low-level write-only Go binding around an Ethereum contract.
type MockERC1271SignerTransactorRaw struct {
	Contract *MockERC1271SignerTransactor // Generic write-only contract binding to access the raw methods on
}

// NewMockERC1271Signer creates a new instance of MockERC1271Signer, bound to a specific deployed contract.
func NewMockERC1271Signer(address common.Address, backend bind.ContractBackend) (*MockERC1271Signer, error) {
	contract, err := bindMockERC1271Signer(address, backend, backend, backend)
	if err != nil {
		return nil, err
	}
	return &MockERC1271Signer{MockERC1271SignerCaller: MockERC1271SignerCaller{contract: contract}, MockERC1271SignerTransactor: MockERC1271SignerTransactor{contract: contract}, MockERC1271SignerFilterer: MockERC1271SignerFilterer{contract: contract}}, nil
}

// NewMockERC1271SignerCaller creates a new read-only instance of MockERC1271Signer, bound to a specific deployed contract.
func NewMockERC1271SignerCaller(address common.Address, caller bind.ContractCaller) (*MockERC1271SignerCaller, error) {
	contract, err := bindMockERC1271Signer(address, caller, nil, nil)
	if err != nil {
		return nil, err
	}
	return &MockERC1271SignerCaller{contract: contract}, nil
}

// NewMockERC1271SignerTransactor creates a new write-only instance of MockERC1271Signer, bound to a specific deployed contract.
func NewMockERC1271SignerTransactor(address common.Address, transactor bind.ContractTransactor) (*MockERC1271SignerTransactor, error) {
	contract, err := bindMockERC1271Signer(address, nil, transactor, nil)
	if err != nil {
		return nil, err
	}
	return &MockERC1271SignerTransactor{contract: contract}, nil
}

// NewMockERC1271SignerFilterer creates a new log filterer instance of MockERC1271Signer, bound to a specific deployed contract.
func NewMockERC1271SignerFilterer(address common.Address, filterer bind.ContractFilterer) (*MockERC1271SignerFilterer, error) {
	contract, err := bindMockERC1271Signer(address, nil, nil, filterer)
	if err != nil {
		return nil, err
	}
	return &MockERC1271SignerFilterer{contract: contract}, nil
}

// bindMockERC1271Signer binds a generic wrapper to an already deployed contract.
func bindMockERC1271Signer(address common.Address, caller bind.ContractCaller, transactor bind.ContractTransactor, filterer bind.ContractFilterer) (*bind.BoundContract, error) {
	parsed, err := MockERC1271SignerMetaData.GetAbi()
	if err != nil {
		return nil, err
	}
	return bind.NewBoundContract(address, *parsed, caller, transactor, filterer), nil
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_MockERC1271Signer *MockERC1271SignerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _MockERC1271Signer.Contract.MockERC1271SignerCaller.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_MockERC1271Signer *MockERC1271SignerRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _MockERC1271Signer.Contract.MockERC1271SignerTransactor.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_MockERC1271Signer *MockERC1271SignerRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _MockERC1271Signer.Contract.MockERC1271SignerTransactor.contract.Transact(opts, method, params...)
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_MockERC1271Signer *MockERC1271SignerCallerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _MockERC1271Signer.Contract.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_MockERC1271Signer *MockERC1271SignerTransactorRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _MockERC1271Signer.Contract.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_MockERC1271Signer *MockERC1271SignerTransactorRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _MockERC1271Signer.Contract.contract.Transact(opts, method, params...)
}

// IsValidSignature is a free data retrieval call binding the contract method 0x1626ba7e.
//
// Solidity: function isValidSignature(bytes32 hash, bytes signature) view returns(bytes4)
func (_MockERC1271Signer *MockERC1271SignerCaller) IsValidSignature(opts *bind.CallOpts, hash [32]byte, signature []byte) ([4]byte, error) {
	var out []interface{}
	err := _MockERC1271Signer.contract.Call(opts, &out, "isValidSignature", hash, signature)

	if err != nil {
		return *new([4]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([4]byte)).(*[4]byte)

	return out0, err

}

// IsValidSignature is a free data retrieval call binding the contract method 0x1626ba7e.
//
// Solidity: function isValidSignature(bytes32 hash, bytes signature) view returns(bytes4)
func (_MockERC1271Signer *MockERC1271SignerSession) IsValidSignature(hash [32]byte, signature []byte) ([4]byte, error) {
	return _MockERC1271Signer.Contract.IsValidSignature(&_MockERC1271Signer.CallOpts, hash, signature)
}

// IsValidSignature is a free data retrieval call binding the contract method 0x1626ba7e.
//
// Solidity: function isValidSignature(bytes32 hash, bytes signature) view returns(bytes4)
func (_MockERC1271Signer *MockERC1271SignerCallerSession) IsValidSignature(hash [32]byte, signature []byte) ([4]byte, error) {
	return _MockERC1271Signer.Contract.IsValidSignature(&_MockERC1271Signer.CallOpts, hash, signature)
}

// Owner is a free data retrieval call binding the contract method 0x8da5cb5b.
//
// Solidity: function owner() view returns(address)
func (_MockERC1271Signer *MockERC1271SignerCaller) Owner(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _MockERC1271Signer.contract.Call(opts, &out, "owner")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Owner is a free data retrieval call binding the contract method 0x8da5cb5b.
//
// Solidity: function owner() view returns(address)
func (_MockERC1271Signer *MockERC1271SignerSession) Owner() (common.Address, error) {
	return _MockERC1271Signer.Contract.Owner(&_MockERC1271Signer.CallOpts)
}

// Owner is a free data retrieval call binding the contract method 0x8da5cb5b.
//
// Solidity: function owner() view returns(address)
func (_MockERC1271Signer *MockERC1271SignerCallerSession) Owner() (common.Address, error) {
	return _MockERC1271Signer.Contract.Owner(&_MockERC1271Signer.CallOpts)
}

// MockUSDMetaData contains all meta data concerning the MockUSD contract.
var MockUSDMetaData = &bind.MetaData{
	ABI: "[{\"inputs\":[{\"internalType\":\"uint8\",\"name\":\"decimals_\",\"type\":\"uint8\"}],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"}],\"name\":\"allowance\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"approve\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"balanceOf\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"decimals\",\"outputs\":[{\"internalType\":\"uint8\",\"name\":\"\",\"type\":\"uint8\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"amount\",\"type\":\"uint256\"}],\"name\":\"mint\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"name\",\"outputs\":[{\"internalType\":\"string\",\"name\":\"\",\"type\":\"string\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"symbol\",\"outputs\":[{\"internalType\":\"string\",\"name\":\"\",\"type\":\"string\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"totalSupply\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"transfer\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"from\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"transferFrom\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"Approval\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"from\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"to\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"Transfer\",\"type\":\"event\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"allowance\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"needed\",\"type\":\"uint256\"}],\"name\":\"ERC20InsufficientAllowance\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"sender\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"balance\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"needed\",\"type\":\"uint256\"}],\"name\":\"ERC20InsufficientBalance\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"approver\",\"type\":\"address\"}],\"name\":\"ERC20InvalidApprover\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"receiver\",\"type\":\"address\"}],\"name\":\"ERC20InvalidReceiver\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"sender\",\"type\":\"address\"}],\"name\":\"ERC20InvalidSender\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"spender\",\"type\":\"address\"}],\"name\":\"ERC20InvalidSpender\",\"type\":\"error\"}]",
	Bin: "0x60a060405234801561000f575f5ffd5b5060405161096838038061096883398101604081905261002e91610096565b60405180604001604052806008815260200167135bd8dac81554d160c21b815250604051806040016040528060048152602001631b5554d160e21b815250816003908161007b9190610160565b5060046100888282610160565b50505060ff1660805261021e565b5f602082840312156100a6575f5ffd5b815160ff811681146100b6575f5ffd5b9392505050565b634e487b7160e01b5f52604160045260245ffd5b600181811c908216806100e557607f821691505b60208210810361010357634e487b7160e01b5f52602260045260245ffd5b50919050565b601f82111561015b578282111561015b57805f5260205f20601f840160051c602085101561013457505f5b90810190601f840160051c035f5b81811015610157575f83820155600101610142565b5050505b505050565b81516001600160401b03811115610179576101796100bd565b61018d8161018784546100d1565b84610109565b6020601f8211600181146101bf575f83156101a85750848201515b5f19600385901b1c1916600184901b178455610217565b5f84815260208120601f198516915b828110156101ee57878501518255602094850194600190920191016101ce565b508482101561020b57868401515f19600387901b60f8161c191681555b505060018360011b0184555b5050505050565b6080516107326102365f395f61010c01526107325ff3fe608060405234801561000f575f5ffd5b506004361061009b575f3560e01c806340c10f191161006357806340c10f191461013657806370a082311461014b57806395d89b4114610173578063a9059cbb1461017b578063dd62ed3e1461018e575f5ffd5b806306fdde031461009f578063095ea7b3146100bd57806318160ddd146100e057806323b872dd146100f2578063313ce56714610105575b5f5ffd5b6100a76101c6565b6040516100b491906105d8565b60405180910390f35b6100d06100cb366004610628565b610256565b60405190151581526020016100b4565b6002545b6040519081526020016100b4565b6100d0610100366004610650565b61026f565b60405160ff7f00000000000000000000000000000000000000000000000000000000000000001681526020016100b4565b610149610144366004610628565b610292565b005b6100e461015936600461068a565b6001600160a01b03165f9081526020819052604090205490565b6100a76102a0565b6100d0610189366004610628565b6102af565b6100e461019c3660046106aa565b6001600160a01b039182165f90815260016020908152604080832093909416825291909152205490565b6060600380546101d5906106db565b80601f0160208091040260200160405190810160405280929190818152602001828054610201906106db565b801561024c5780601f106102235761010080835404028352916020019161024c565b820191905f5260205f20905b81548152906001019060200180831161022f57829003601f168201915b5050505050905090565b5f336102638185856102bc565b60019150505b92915050565b5f3361027c8582856102ce565b61028785858561034f565b506001949350505050565b61029c82826103ac565b5050565b6060600480546101d5906106db565b5f3361026381858561034f565b6102c983838360016103e0565b505050565b6001600160a01b038381165f908152600160209081526040808320938616835292905220545f19811015610349578181101561033b57604051637dc7a0d960e11b81526001600160a01b038416600482015260248101829052604481018390526064015b60405180910390fd5b61034984848484035f6103e0565b50505050565b6001600160a01b03831661037857604051634b637e8f60e11b81525f6004820152602401610332565b6001600160a01b0382166103a15760405163ec442f0560e01b81525f6004820152602401610332565b6102c98383836104b2565b6001600160a01b0382166103d55760405163ec442f0560e01b81525f6004820152602401610332565b61029c5f83836104b2565b6001600160a01b0384166104095760405163e602df0560e01b81525f6004820152602401610332565b6001600160a01b03831661043257604051634a1406b160e11b81525f6004820152602401610332565b6001600160a01b038085165f908152600160209081526040808320938716835292905220829055801561034957826001600160a01b0316846001600160a01b03167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925846040516104a491815260200190565b60405180910390a350505050565b6001600160a01b0383166104dc578060025f8282546104d19190610713565b9091555061054c9050565b6001600160a01b0383165f908152602081905260409020548181101561052e5760405163391434e360e21b81526001600160a01b03851660048201526024810182905260448101839052606401610332565b6001600160a01b0384165f9081526020819052604090209082900390555b6001600160a01b03821661056857600280548290039055610586565b6001600160a01b0382165f9081526020819052604090208054820190555b816001600160a01b0316836001600160a01b03167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef836040516105cb91815260200190565b60405180910390a3505050565b602081525f82518060208401528060208501604085015e5f604082850101526040601f19601f83011684010191505092915050565b80356001600160a01b0381168114610623575f5ffd5b919050565b5f5f60408385031215610639575f5ffd5b6106428361060d565b946020939093013593505050565b5f5f5f60608486031215610662575f5ffd5b61066b8461060d565b92506106796020850161060d565b929592945050506040919091013590565b5f6020828403121561069a575f5ffd5b6106a38261060d565b9392505050565b5f5f604083850312156106bb575f5ffd5b6106c48361060d565b91506106d26020840161060d565b90509250929050565b600181811c908216806106ef57607f821691505b60208210810361070d57634e487b7160e01b5f52602260045260245ffd5b50919050565b8082018082111561026957634e487b7160e01b5f52601160045260245ffd",
}

// MockUSDABI is the input ABI used to generate the binding from.
// Deprecated: Use MockUSDMetaData.ABI instead.
var MockUSDABI = MockUSDMetaData.ABI

// MockUSDBin is the compiled bytecode used for deploying new contracts.
// Deprecated: Use MockUSDMetaData.Bin instead.
var MockUSDBin = MockUSDMetaData.Bin

// DeployMockUSD deploys a new Ethereum contract, binding an instance of MockUSD to it.
func DeployMockUSD(auth *bind.TransactOpts, backend bind.ContractBackend, decimals_ uint8) (common.Address, *types.Transaction, *MockUSD, error) {
	parsed, err := MockUSDMetaData.GetAbi()
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	if parsed == nil {
		return common.Address{}, nil, nil, errors.New("GetABI returned nil")
	}

	address, tx, contract, err := bind.DeployContract(auth, *parsed, common.FromHex(MockUSDBin), backend, decimals_)
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	return address, tx, &MockUSD{MockUSDCaller: MockUSDCaller{contract: contract}, MockUSDTransactor: MockUSDTransactor{contract: contract}, MockUSDFilterer: MockUSDFilterer{contract: contract}}, nil
}

// MockUSD is an auto generated Go binding around an Ethereum contract.
type MockUSD struct {
	MockUSDCaller     // Read-only binding to the contract
	MockUSDTransactor // Write-only binding to the contract
	MockUSDFilterer   // Log filterer for contract events
}

// MockUSDCaller is an auto generated read-only Go binding around an Ethereum contract.
type MockUSDCaller struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// MockUSDTransactor is an auto generated write-only Go binding around an Ethereum contract.
type MockUSDTransactor struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// MockUSDFilterer is an auto generated log filtering Go binding around an Ethereum contract events.
type MockUSDFilterer struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// MockUSDSession is an auto generated Go binding around an Ethereum contract,
// with pre-set call and transact options.
type MockUSDSession struct {
	Contract     *MockUSD          // Generic contract binding to set the session for
	CallOpts     bind.CallOpts     // Call options to use throughout this session
	TransactOpts bind.TransactOpts // Transaction auth options to use throughout this session
}

// MockUSDCallerSession is an auto generated read-only Go binding around an Ethereum contract,
// with pre-set call options.
type MockUSDCallerSession struct {
	Contract *MockUSDCaller // Generic contract caller binding to set the session for
	CallOpts bind.CallOpts  // Call options to use throughout this session
}

// MockUSDTransactorSession is an auto generated write-only Go binding around an Ethereum contract,
// with pre-set transact options.
type MockUSDTransactorSession struct {
	Contract     *MockUSDTransactor // Generic contract transactor binding to set the session for
	TransactOpts bind.TransactOpts  // Transaction auth options to use throughout this session
}

// MockUSDRaw is an auto generated low-level Go binding around an Ethereum contract.
type MockUSDRaw struct {
	Contract *MockUSD // Generic contract binding to access the raw methods on
}

// MockUSDCallerRaw is an auto generated low-level read-only Go binding around an Ethereum contract.
type MockUSDCallerRaw struct {
	Contract *MockUSDCaller // Generic read-only contract binding to access the raw methods on
}

// MockUSDTransactorRaw is an auto generated low-level write-only Go binding around an Ethereum contract.
type MockUSDTransactorRaw struct {
	Contract *MockUSDTransactor // Generic write-only contract binding to access the raw methods on
}

// NewMockUSD creates a new instance of MockUSD, bound to a specific deployed contract.
func NewMockUSD(address common.Address, backend bind.ContractBackend) (*MockUSD, error) {
	contract, err := bindMockUSD(address, backend, backend, backend)
	if err != nil {
		return nil, err
	}
	return &MockUSD{MockUSDCaller: MockUSDCaller{contract: contract}, MockUSDTransactor: MockUSDTransactor{contract: contract}, MockUSDFilterer: MockUSDFilterer{contract: contract}}, nil
}

// NewMockUSDCaller creates a new read-only instance of MockUSD, bound to a specific deployed contract.
func NewMockUSDCaller(address common.Address, caller bind.ContractCaller) (*MockUSDCaller, error) {
	contract, err := bindMockUSD(address, caller, nil, nil)
	if err != nil {
		return nil, err
	}
	return &MockUSDCaller{contract: contract}, nil
}

// NewMockUSDTransactor creates a new write-only instance of MockUSD, bound to a specific deployed contract.
func NewMockUSDTransactor(address common.Address, transactor bind.ContractTransactor) (*MockUSDTransactor, error) {
	contract, err := bindMockUSD(address, nil, transactor, nil)
	if err != nil {
		return nil, err
	}
	return &MockUSDTransactor{contract: contract}, nil
}

// NewMockUSDFilterer creates a new log filterer instance of MockUSD, bound to a specific deployed contract.
func NewMockUSDFilterer(address common.Address, filterer bind.ContractFilterer) (*MockUSDFilterer, error) {
	contract, err := bindMockUSD(address, nil, nil, filterer)
	if err != nil {
		return nil, err
	}
	return &MockUSDFilterer{contract: contract}, nil
}

// bindMockUSD binds a generic wrapper to an already deployed contract.
func bindMockUSD(address common.Address, caller bind.ContractCaller, transactor bind.ContractTransactor, filterer bind.ContractFilterer) (*bind.BoundContract, error) {
	parsed, err := MockUSDMetaData.GetAbi()
	if err != nil {
		return nil, err
	}
	return bind.NewBoundContract(address, *parsed, caller, transactor, filterer), nil
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_MockUSD *MockUSDRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _MockUSD.Contract.MockUSDCaller.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_MockUSD *MockUSDRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _MockUSD.Contract.MockUSDTransactor.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_MockUSD *MockUSDRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _MockUSD.Contract.MockUSDTransactor.contract.Transact(opts, method, params...)
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_MockUSD *MockUSDCallerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _MockUSD.Contract.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_MockUSD *MockUSDTransactorRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _MockUSD.Contract.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_MockUSD *MockUSDTransactorRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _MockUSD.Contract.contract.Transact(opts, method, params...)
}

// Allowance is a free data retrieval call binding the contract method 0xdd62ed3e.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (_MockUSD *MockUSDCaller) Allowance(opts *bind.CallOpts, owner common.Address, spender common.Address) (*big.Int, error) {
	var out []interface{}
	err := _MockUSD.contract.Call(opts, &out, "allowance", owner, spender)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// Allowance is a free data retrieval call binding the contract method 0xdd62ed3e.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (_MockUSD *MockUSDSession) Allowance(owner common.Address, spender common.Address) (*big.Int, error) {
	return _MockUSD.Contract.Allowance(&_MockUSD.CallOpts, owner, spender)
}

// Allowance is a free data retrieval call binding the contract method 0xdd62ed3e.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (_MockUSD *MockUSDCallerSession) Allowance(owner common.Address, spender common.Address) (*big.Int, error) {
	return _MockUSD.Contract.Allowance(&_MockUSD.CallOpts, owner, spender)
}

// BalanceOf is a free data retrieval call binding the contract method 0x70a08231.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (_MockUSD *MockUSDCaller) BalanceOf(opts *bind.CallOpts, account common.Address) (*big.Int, error) {
	var out []interface{}
	err := _MockUSD.contract.Call(opts, &out, "balanceOf", account)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// BalanceOf is a free data retrieval call binding the contract method 0x70a08231.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (_MockUSD *MockUSDSession) BalanceOf(account common.Address) (*big.Int, error) {
	return _MockUSD.Contract.BalanceOf(&_MockUSD.CallOpts, account)
}

// BalanceOf is a free data retrieval call binding the contract method 0x70a08231.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (_MockUSD *MockUSDCallerSession) BalanceOf(account common.Address) (*big.Int, error) {
	return _MockUSD.Contract.BalanceOf(&_MockUSD.CallOpts, account)
}

// Decimals is a free data retrieval call binding the contract method 0x313ce567.
//
// Solidity: function decimals() view returns(uint8)
func (_MockUSD *MockUSDCaller) Decimals(opts *bind.CallOpts) (uint8, error) {
	var out []interface{}
	err := _MockUSD.contract.Call(opts, &out, "decimals")

	if err != nil {
		return *new(uint8), err
	}

	out0 := *abi.ConvertType(out[0], new(uint8)).(*uint8)

	return out0, err

}

// Decimals is a free data retrieval call binding the contract method 0x313ce567.
//
// Solidity: function decimals() view returns(uint8)
func (_MockUSD *MockUSDSession) Decimals() (uint8, error) {
	return _MockUSD.Contract.Decimals(&_MockUSD.CallOpts)
}

// Decimals is a free data retrieval call binding the contract method 0x313ce567.
//
// Solidity: function decimals() view returns(uint8)
func (_MockUSD *MockUSDCallerSession) Decimals() (uint8, error) {
	return _MockUSD.Contract.Decimals(&_MockUSD.CallOpts)
}

// Name is a free data retrieval call binding the contract method 0x06fdde03.
//
// Solidity: function name() view returns(string)
func (_MockUSD *MockUSDCaller) Name(opts *bind.CallOpts) (string, error) {
	var out []interface{}
	err := _MockUSD.contract.Call(opts, &out, "name")

	if err != nil {
		return *new(string), err
	}

	out0 := *abi.ConvertType(out[0], new(string)).(*string)

	return out0, err

}

// Name is a free data retrieval call binding the contract method 0x06fdde03.
//
// Solidity: function name() view returns(string)
func (_MockUSD *MockUSDSession) Name() (string, error) {
	return _MockUSD.Contract.Name(&_MockUSD.CallOpts)
}

// Name is a free data retrieval call binding the contract method 0x06fdde03.
//
// Solidity: function name() view returns(string)
func (_MockUSD *MockUSDCallerSession) Name() (string, error) {
	return _MockUSD.Contract.Name(&_MockUSD.CallOpts)
}

// Symbol is a free data retrieval call binding the contract method 0x95d89b41.
//
// Solidity: function symbol() view returns(string)
func (_MockUSD *MockUSDCaller) Symbol(opts *bind.CallOpts) (string, error) {
	var out []interface{}
	err := _MockUSD.contract.Call(opts, &out, "symbol")

	if err != nil {
		return *new(string), err
	}

	out0 := *abi.ConvertType(out[0], new(string)).(*string)

	return out0, err

}

// Symbol is a free data retrieval call binding the contract method 0x95d89b41.
//
// Solidity: function symbol() view returns(string)
func (_MockUSD *MockUSDSession) Symbol() (string, error) {
	return _MockUSD.Contract.Symbol(&_MockUSD.CallOpts)
}

// Symbol is a free data retrieval call binding the contract method 0x95d89b41.
//
// Solidity: function symbol() view returns(string)
func (_MockUSD *MockUSDCallerSession) Symbol() (string, error) {
	return _MockUSD.Contract.Symbol(&_MockUSD.CallOpts)
}

// TotalSupply is a free data retrieval call binding the contract method 0x18160ddd.
//
// Solidity: function totalSupply() view returns(uint256)
func (_MockUSD *MockUSDCaller) TotalSupply(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _MockUSD.contract.Call(opts, &out, "totalSupply")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// TotalSupply is a free data retrieval call binding the contract method 0x18160ddd.
//
// Solidity: function totalSupply() view returns(uint256)
func (_MockUSD *MockUSDSession) TotalSupply() (*big.Int, error) {
	return _MockUSD.Contract.TotalSupply(&_MockUSD.CallOpts)
}

// TotalSupply is a free data retrieval call binding the contract method 0x18160ddd.
//
// Solidity: function totalSupply() view returns(uint256)
func (_MockUSD *MockUSDCallerSession) TotalSupply() (*big.Int, error) {
	return _MockUSD.Contract.TotalSupply(&_MockUSD.CallOpts)
}

// Approve is a paid mutator transaction binding the contract method 0x095ea7b3.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (_MockUSD *MockUSDTransactor) Approve(opts *bind.TransactOpts, spender common.Address, value *big.Int) (*types.Transaction, error) {
	return _MockUSD.contract.Transact(opts, "approve", spender, value)
}

// Approve is a paid mutator transaction binding the contract method 0x095ea7b3.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (_MockUSD *MockUSDSession) Approve(spender common.Address, value *big.Int) (*types.Transaction, error) {
	return _MockUSD.Contract.Approve(&_MockUSD.TransactOpts, spender, value)
}

// Approve is a paid mutator transaction binding the contract method 0x095ea7b3.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (_MockUSD *MockUSDTransactorSession) Approve(spender common.Address, value *big.Int) (*types.Transaction, error) {
	return _MockUSD.Contract.Approve(&_MockUSD.TransactOpts, spender, value)
}

// Mint is a paid mutator transaction binding the contract method 0x40c10f19.
//
// Solidity: function mint(address to, uint256 amount) returns()
func (_MockUSD *MockUSDTransactor) Mint(opts *bind.TransactOpts, to common.Address, amount *big.Int) (*types.Transaction, error) {
	return _MockUSD.contract.Transact(opts, "mint", to, amount)
}

// Mint is a paid mutator transaction binding the contract method 0x40c10f19.
//
// Solidity: function mint(address to, uint256 amount) returns()
func (_MockUSD *MockUSDSession) Mint(to common.Address, amount *big.Int) (*types.Transaction, error) {
	return _MockUSD.Contract.Mint(&_MockUSD.TransactOpts, to, amount)
}

// Mint is a paid mutator transaction binding the contract method 0x40c10f19.
//
// Solidity: function mint(address to, uint256 amount) returns()
func (_MockUSD *MockUSDTransactorSession) Mint(to common.Address, amount *big.Int) (*types.Transaction, error) {
	return _MockUSD.Contract.Mint(&_MockUSD.TransactOpts, to, amount)
}

// Transfer is a paid mutator transaction binding the contract method 0xa9059cbb.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (_MockUSD *MockUSDTransactor) Transfer(opts *bind.TransactOpts, to common.Address, value *big.Int) (*types.Transaction, error) {
	return _MockUSD.contract.Transact(opts, "transfer", to, value)
}

// Transfer is a paid mutator transaction binding the contract method 0xa9059cbb.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (_MockUSD *MockUSDSession) Transfer(to common.Address, value *big.Int) (*types.Transaction, error) {
	return _MockUSD.Contract.Transfer(&_MockUSD.TransactOpts, to, value)
}

// Transfer is a paid mutator transaction binding the contract method 0xa9059cbb.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (_MockUSD *MockUSDTransactorSession) Transfer(to common.Address, value *big.Int) (*types.Transaction, error) {
	return _MockUSD.Contract.Transfer(&_MockUSD.TransactOpts, to, value)
}

// TransferFrom is a paid mutator transaction binding the contract method 0x23b872dd.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (_MockUSD *MockUSDTransactor) TransferFrom(opts *bind.TransactOpts, from common.Address, to common.Address, value *big.Int) (*types.Transaction, error) {
	return _MockUSD.contract.Transact(opts, "transferFrom", from, to, value)
}

// TransferFrom is a paid mutator transaction binding the contract method 0x23b872dd.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (_MockUSD *MockUSDSession) TransferFrom(from common.Address, to common.Address, value *big.Int) (*types.Transaction, error) {
	return _MockUSD.Contract.TransferFrom(&_MockUSD.TransactOpts, from, to, value)
}

// TransferFrom is a paid mutator transaction binding the contract method 0x23b872dd.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (_MockUSD *MockUSDTransactorSession) TransferFrom(from common.Address, to common.Address, value *big.Int) (*types.Transaction, error) {
	return _MockUSD.Contract.TransferFrom(&_MockUSD.TransactOpts, from, to, value)
}

// MockUSDApprovalIterator is returned from FilterApproval and is used to iterate over the raw logs and unpacked data for Approval events raised by the MockUSD contract.
type MockUSDApprovalIterator struct {
	Event *MockUSDApproval // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *MockUSDApprovalIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(MockUSDApproval)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(MockUSDApproval)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *MockUSDApprovalIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *MockUSDApprovalIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// MockUSDApproval represents a Approval event raised by the MockUSD contract.
type MockUSDApproval struct {
	Owner   common.Address
	Spender common.Address
	Value   *big.Int
	Raw     types.Log // Blockchain specific contextual infos
}

// FilterApproval is a free log retrieval operation binding the contract event 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925.
//
// Solidity: event Approval(address indexed owner, address indexed spender, uint256 value)
func (_MockUSD *MockUSDFilterer) FilterApproval(opts *bind.FilterOpts, owner []common.Address, spender []common.Address) (*MockUSDApprovalIterator, error) {

	var ownerRule []interface{}
	for _, ownerItem := range owner {
		ownerRule = append(ownerRule, ownerItem)
	}
	var spenderRule []interface{}
	for _, spenderItem := range spender {
		spenderRule = append(spenderRule, spenderItem)
	}

	logs, sub, err := _MockUSD.contract.FilterLogs(opts, "Approval", ownerRule, spenderRule)
	if err != nil {
		return nil, err
	}
	return &MockUSDApprovalIterator{contract: _MockUSD.contract, event: "Approval", logs: logs, sub: sub}, nil
}

// WatchApproval is a free log subscription operation binding the contract event 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925.
//
// Solidity: event Approval(address indexed owner, address indexed spender, uint256 value)
func (_MockUSD *MockUSDFilterer) WatchApproval(opts *bind.WatchOpts, sink chan<- *MockUSDApproval, owner []common.Address, spender []common.Address) (event.Subscription, error) {

	var ownerRule []interface{}
	for _, ownerItem := range owner {
		ownerRule = append(ownerRule, ownerItem)
	}
	var spenderRule []interface{}
	for _, spenderItem := range spender {
		spenderRule = append(spenderRule, spenderItem)
	}

	logs, sub, err := _MockUSD.contract.WatchLogs(opts, "Approval", ownerRule, spenderRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(MockUSDApproval)
				if err := _MockUSD.contract.UnpackLog(event, "Approval", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseApproval is a log parse operation binding the contract event 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925.
//
// Solidity: event Approval(address indexed owner, address indexed spender, uint256 value)
func (_MockUSD *MockUSDFilterer) ParseApproval(log types.Log) (*MockUSDApproval, error) {
	event := new(MockUSDApproval)
	if err := _MockUSD.contract.UnpackLog(event, "Approval", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// MockUSDTransferIterator is returned from FilterTransfer and is used to iterate over the raw logs and unpacked data for Transfer events raised by the MockUSD contract.
type MockUSDTransferIterator struct {
	Event *MockUSDTransfer // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *MockUSDTransferIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(MockUSDTransfer)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(MockUSDTransfer)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *MockUSDTransferIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *MockUSDTransferIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// MockUSDTransfer represents a Transfer event raised by the MockUSD contract.
type MockUSDTransfer struct {
	From  common.Address
	To    common.Address
	Value *big.Int
	Raw   types.Log // Blockchain specific contextual infos
}

// FilterTransfer is a free log retrieval operation binding the contract event 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef.
//
// Solidity: event Transfer(address indexed from, address indexed to, uint256 value)
func (_MockUSD *MockUSDFilterer) FilterTransfer(opts *bind.FilterOpts, from []common.Address, to []common.Address) (*MockUSDTransferIterator, error) {

	var fromRule []interface{}
	for _, fromItem := range from {
		fromRule = append(fromRule, fromItem)
	}
	var toRule []interface{}
	for _, toItem := range to {
		toRule = append(toRule, toItem)
	}

	logs, sub, err := _MockUSD.contract.FilterLogs(opts, "Transfer", fromRule, toRule)
	if err != nil {
		return nil, err
	}
	return &MockUSDTransferIterator{contract: _MockUSD.contract, event: "Transfer", logs: logs, sub: sub}, nil
}

// WatchTransfer is a free log subscription operation binding the contract event 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef.
//
// Solidity: event Transfer(address indexed from, address indexed to, uint256 value)
func (_MockUSD *MockUSDFilterer) WatchTransfer(opts *bind.WatchOpts, sink chan<- *MockUSDTransfer, from []common.Address, to []common.Address) (event.Subscription, error) {

	var fromRule []interface{}
	for _, fromItem := range from {
		fromRule = append(fromRule, fromItem)
	}
	var toRule []interface{}
	for _, toItem := range to {
		toRule = append(toRule, toItem)
	}

	logs, sub, err := _MockUSD.contract.WatchLogs(opts, "Transfer", fromRule, toRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(MockUSDTransfer)
				if err := _MockUSD.contract.UnpackLog(event, "Transfer", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseTransfer is a log parse operation binding the contract event 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef.
//
// Solidity: event Transfer(address indexed from, address indexed to, uint256 value)
func (_MockUSD *MockUSDFilterer) ParseTransfer(log types.Log) (*MockUSDTransfer, error) {
	event := new(MockUSDTransfer)
	if err := _MockUSD.contract.UnpackLog(event, "Transfer", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// OracleVerifierMetaData contains all meta data concerning the OracleVerifier contract.
var OracleVerifierMetaData = &bind.MetaData{
	ABI: "[{\"inputs\":[{\"internalType\":\"address\",\"name\":\"authority_\",\"type\":\"address\"},{\"internalType\":\"address[]\",\"name\":\"initialSigners\",\"type\":\"address[]\"},{\"internalType\":\"uint8\",\"name\":\"initialMinSigners\",\"type\":\"uint8\"},{\"internalType\":\"uint32\",\"name\":\"initialMaxReportAge\",\"type\":\"uint32\"},{\"internalType\":\"uint16\",\"name\":\"initialMaxSpreadBps\",\"type\":\"uint16\"}],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"inputs\":[],\"name\":\"MAX_REPORT_AGE_LIMIT\",\"outputs\":[{\"internalType\":\"uint32\",\"name\":\"\",\"type\":\"uint32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"MAX_SIGNERS\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"MAX_SPREAD_LIMIT_BPS\",\"outputs\":[{\"internalType\":\"uint16\",\"name\":\"\",\"type\":\"uint16\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"PRICE_REPORT_TYPEHASH\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"authority\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"domainSeparator\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"eip712Domain\",\"outputs\":[{\"internalType\":\"bytes1\",\"name\":\"fields\",\"type\":\"bytes1\"},{\"internalType\":\"string\",\"name\":\"name\",\"type\":\"string\"},{\"internalType\":\"string\",\"name\":\"version\",\"type\":\"string\"},{\"internalType\":\"uint256\",\"name\":\"chainId\",\"type\":\"uint256\"},{\"internalType\":\"address\",\"name\":\"verifyingContract\",\"type\":\"address\"},{\"internalType\":\"bytes32\",\"name\":\"salt\",\"type\":\"bytes32\"},{\"internalType\":\"uint256[]\",\"name\":\"extensions\",\"type\":\"uint256[]\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"isConsumingScheduledOp\",\"outputs\":[{\"internalType\":\"bytes4\",\"name\":\"\",\"type\":\"bytes4\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"}],\"name\":\"isSigner\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"maxReportAge\",\"outputs\":[{\"internalType\":\"uint32\",\"name\":\"\",\"type\":\"uint32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"maxSpreadBps\",\"outputs\":[{\"internalType\":\"uint16\",\"name\":\"\",\"type\":\"uint16\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"minSigners\",\"outputs\":[{\"internalType\":\"uint8\",\"name\":\"\",\"type\":\"uint8\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"marketId\",\"type\":\"bytes32\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint64\",\"name\":\"timestamp\",\"type\":\"uint64\"}],\"name\":\"reportDigest\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"newAuthority\",\"type\":\"address\"}],\"name\":\"setAuthority\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint32\",\"name\":\"newMaxReportAge\",\"type\":\"uint32\"},{\"internalType\":\"uint16\",\"name\":\"newMaxSpreadBps\",\"type\":\"uint16\"}],\"name\":\"setReportLimits\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address[]\",\"name\":\"newSigners\",\"type\":\"address[]\"},{\"internalType\":\"uint8\",\"name\":\"newMinSigners\",\"type\":\"uint8\"}],\"name\":\"setSigners\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"signers\",\"outputs\":[{\"internalType\":\"address[]\",\"name\":\"\",\"type\":\"address[]\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bytes32\",\"name\":\"marketId\",\"type\":\"bytes32\"},{\"components\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint64\",\"name\":\"timestamp\",\"type\":\"uint64\"},{\"internalType\":\"bytes\",\"name\":\"signature\",\"type\":\"bytes\"}],\"internalType\":\"structIOracleVerifier.SignedPriceReport[]\",\"name\":\"reports\",\"type\":\"tuple[]\"},{\"internalType\":\"uint256\",\"name\":\"requestTimestamp\",\"type\":\"uint256\"}],\"name\":\"verifyReports\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"medianPrice\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"oldestTimestamp\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"address\",\"name\":\"authority\",\"type\":\"address\"}],\"name\":\"AuthorityUpdated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[],\"name\":\"EIP712DomainChanged\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"uint32\",\"name\":\"maxReportAge\",\"type\":\"uint32\"},{\"indexed\":false,\"internalType\":\"uint16\",\"name\":\"maxSpreadBps\",\"type\":\"uint16\"}],\"name\":\"ReportLimitsUpdated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"address[]\",\"name\":\"signers\",\"type\":\"address[]\"},{\"indexed\":false,\"internalType\":\"uint8\",\"name\":\"minSigners\",\"type\":\"uint8\"}],\"name\":\"SignerSetUpdated\",\"type\":\"event\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"authority\",\"type\":\"address\"}],\"name\":\"AccessManagedInvalidAuthority\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"uint32\",\"name\":\"delay\",\"type\":\"uint32\"}],\"name\":\"AccessManagedRequiredDelay\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"}],\"name\":\"AccessManagedUnauthorized\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"}],\"name\":\"DuplicateSigner\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint8\",\"name\":\"minSigners\",\"type\":\"uint8\"},{\"internalType\":\"uint256\",\"name\":\"size\",\"type\":\"uint256\"}],\"name\":\"InvalidQuorum\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint32\",\"name\":\"maxReportAge\",\"type\":\"uint32\"},{\"internalType\":\"uint16\",\"name\":\"maxSpreadBps\",\"type\":\"uint16\"}],\"name\":\"InvalidReportLimits\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"InvalidShortString\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"}],\"name\":\"InvalidSignature\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"}],\"name\":\"InvalidSignerEntry\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"size\",\"type\":\"uint256\"}],\"name\":\"InvalidSignerSetSize\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"provided\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"required\",\"type\":\"uint256\"}],\"name\":\"NotEnoughReports\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"timestamp\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"blockTimestamp\",\"type\":\"uint256\"}],\"name\":\"ReportFromFuture\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"timestamp\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"requestTimestamp\",\"type\":\"uint256\"}],\"name\":\"ReportPredatesRequest\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"minPrice\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"maxPrice\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"medianPrice\",\"type\":\"uint256\"},{\"internalType\":\"uint16\",\"name\":\"maxSpreadBps\",\"type\":\"uint16\"}],\"name\":\"SpreadTooWide\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"timestamp\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"oldestAllowed\",\"type\":\"uint256\"}],\"name\":\"StaleReport\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"string\",\"name\":\"str\",\"type\":\"string\"}],\"name\":\"StringTooLong\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"provided\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"maxAllowed\",\"type\":\"uint256\"}],\"name\":\"TooManyReports\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"}],\"name\":\"UnknownSigner\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"}],\"name\":\"ZeroPrice\",\"type\":\"error\"}]",
	Bin: "0x610160604052348015610010575f5ffd5b506040516121a63803806121a683398101604081905261002f9161058d565b6040518060400160405280600b81526020016a50657270734f7261636c6560a81b815250604051806040016040528060018152602001603160f81b8152508661007d8161014760201b60201c565b506100878261019a565b610120526100948161019a565b61014052815160208084019190912060e052815190820120610100524660a05261012060e05161010051604080517f8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f60208201529081019290925260608201524660808201523060a08201525f9060c00160405160208183030381529060405280519060200120905090565b60805250503060c05261013384846101e0565b61013d8282610406565b5050505050610787565b5f80546001600160a01b0319166001600160a01b0383169081179091556040519081527f2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad9060200160405180910390a150565b5f5f829050601f815111156101cd578260405163305a27a960e01b81526004016101c4919061069a565b60405180910390fd5b80516101d8826106cf565b179392505050565b815180158015906101f2575060108111155b8190610214576040516307f6043b60e41b81526004016101c491815260200190565b5060028260ff161015801561022c5750808260ff1611155b828290916102585760405163830287af60e01b815260ff909216600483015260248201526044016101c4565b50506003545f5b818110156102a95760045f6003838154811061027d5761027d6106f5565b5f9182526020808320909101546001600160a01b0316835282019290925260400181205560010161025f565b506102b560035f6104f4565b5f5b828110156103b6575f8582815181106102d2576102d26106f5565b602002602001015190505f6001600160a01b0316816001600160a01b03161415801561031357506001600160a01b0381165f90815260046020526040902054155b819061033e5760405163311afa8f60e01b81526001600160a01b0390911660048201526024016101c4565b5060038054600180820183555f929092527fc2575a0e9e593c00f959f8c92f12db2869c3395a3b0502d05e2516446f71f85b0180546001600160a01b0319166001600160a01b038416179055610395908390610709565b6001600160a01b039091165f908152600460205260409020556001016102b7565b506005805460ff191660ff85161790556040517f77ab1b4817128e6561abaf5f56ed3393a4032181938849f5ff1277e2583413a0906103f8908690869061072e565b60405180910390a150505050565b63ffffffff821615801590610423575061025863ffffffff831611155b8015610432575061ffff811615155b801561044457506101f461ffff821611155b828290916104775760405163ad82b17760e01b815263ffffffff909216600483015261ffff1660248201526044016101c4565b50506005805466ffffffffffff00191661010063ffffffff851690810261ffff60281b1916919091176501000000000061ffff8516908102919091179092556040805191825260208201929092527fce44ae4eb3bc5a303e0bc68d713d264ec808b55560f90fc9d5b4888b347d26c8910160405180910390a15050565b5080545f8255905f5260205f209061050c919061050e565b565b5f5b80821115610525575f81840155600101610510565b505050565b80516001600160a01b0381168114610540575f5ffd5b919050565b634e487b7160e01b5f52604160045260245ffd5b805160ff81168114610540575f5ffd5b805163ffffffff81168114610540575f5ffd5b805161ffff81168114610540575f5ffd5b5f5f5f5f5f60a086880312156105a1575f5ffd5b6105aa8661052a565b60208701519095506001600160401b038111156105c5575f5ffd5b8601601f810188136105d5575f5ffd5b80516001600160401b038111156105ee576105ee610545565b604051600582901b90603f8201601f191681016001600160401b038111828210171561061c5761061c610545565b60405291825260208184018101929081018b841115610639575f5ffd5b6020850194505b8385101561065f576106518561052a565b815260209485019401610640565b5096506106729250505060408701610559565b925061068060608701610569565b915061068e6080870161057c565b90509295509295909350565b602081525f82518060208401528060208501604085015e5f604082850101526040601f19601f83011684010191505092915050565b805160208083015191908110156106ef575f198160200360031b1b821691505b50919050565b634e487b7160e01b5f52603260045260245ffd5b8082018082111561072857634e487b7160e01b5f52601160045260245ffd5b92915050565b604080825283519082018190525f9060208501906060840190835b818110156107705783516001600160a01b0316835260209384019390920191600101610749565b5050809250505060ff831660208301529392505050565b60805160a05160c05160e0516101005161012051610140516119ce6107d85f395f610e4401525f610e1901525f61116701525f61113f01525f61109a01525f6110c401525f6110ee01526119ce5ff3fe608060405234801561000f575f5ffd5b5060043610610111575f3560e01c80638c756a401161009e578063bf7e214f1161006e578063bf7e214f1461029e578063c0afe83b146102b8578063c45e0d24146102cf578063daf3f08b146102e4578063f698da25146102f7575f5ffd5b80638c756a40146102195780638fb3603714610237578063ae3c994114610258578063b70f7e841461027f575f5ffd5b806346f0975a116100e457806346f0975a1461019457806359ecd657146101a95780637a9e5e4b146101b15780637df73e27146101c457806384b0196e146101fe575f5ffd5b80631d5b02ba1461011557806327552f6d1461012a57806328726083146101575780632b53933a14610173575b5f5ffd5b6101286101233660046114c9565b6102ff565b005b61013d610138366004611555565b610319565b604080519283526020830191909152015b60405180910390f35b6101606101f481565b60405161ffff909116815260200161014e565b6101866101813660046115be565b61064d565b60405190815260200161014e565b61019c6106c0565b60405161014e9190611633565b610186601081565b6101286101bf36600461164c565b610720565b6101ee6101d236600461164c565b6001600160a01b03165f90815260046020526040902054151590565b604051901515815260200161014e565b610206610794565b60405161014e97969594939291906116a0565b61022261025881565b60405163ffffffff909116815260200161014e565b61023f6107d6565b6040516001600160e01b0319909116815260200161014e565b6101867ff0a4e89bae3cce4cffe5c4c2423f4713b00c86897bd825ebcff34a4e1b4100b381565b60055461028c9060ff1681565b60405160ff909116815260200161014e565b5f546040516001600160a01b03909116815260200161014e565b6005546101609065010000000000900461ffff1681565b60055461022290610100900463ffffffff1681565b6101286102f2366004611736565b6107fa565b610186610845565b61030b335b5f3661084e565b6103158282610944565b5050565b6005546003545f918291859160ff169082828082101561035a57604051633c7e55b560e21b8152600481019290925260248201526044015b60405180910390fd5b50839050818082111561038957604051637da0a3cd60e11b815260048101929092526024820152604401610351565b50505f836001600160401b038111156103a4576103a461178d565b6040519080825280602002602001820160405280156103cd578160200160208202803683370190505b506005549091505f908190610100900463ffffffff1642116103ef575f610407565b60055461040790610100900463ffffffff16426117b5565b90505f1996505f5b868110156104e257368c8c8381811061042a5761042a6117c8565b905060200281019061043c91906117dc565b90505f61044b8f83868f610a34565b90508481161561045e602084018461164c565b9061048857604051637010e27960e11b81526001600160a01b039091166004820152602401610351565b50938417938961049e60608401604085016117fa565b6001600160401b031610156104c9576104bd60608301604084016117fa565b6001600160401b031699505b6104d886848460200135610cdf565b505060010161040f565b505f6104ef600288611827565b90506104fc60028861183a565b60011461055e576002848281518110610517576105176117c8565b60200260200101518560018461052d91906117b5565b8151811061053d5761053d6117c8565b602002602001015161054f919061184d565b6105599190611827565b610579565b838181518110610570576105706117c8565b60200260200101515b98505f845f8151811061058e5761058e6117c8565b602002602001015190505f8560018a6105a791906117b5565b815181106105b7576105b76117c8565b602090810291909101015160055490915065010000000000900461ffff166105df8c82611860565b6105e984846117b5565b6105f590612710611860565b111583838e849091929361063657604051637aac714b60e11b815260048101949094526024840192909252604483015261ffff166064820152608401610351565b505050505050505050505050505094509492505050565b604080517ff0a4e89bae3cce4cffe5c4c2423f4713b00c86897bd825ebcff34a4e1b4100b36020820152908101849052606081018390526001600160401b03821660808201525f906106b89060a0015b60405160208183030381529060405280519060200120610d8d565b949350505050565b6060600380548060200260200160405190810160405280929190818152602001828054801561071657602002820191905f5260205f20905b81546001600160a01b031681526001909101906020018083116106f8575b5050505050905090565b5f5433906001600160a01b031681146107565760405162d1953b60e31b81526001600160a01b0382166004820152602401610351565b816001600160a01b03163b5f0361078b576040516361798f2f60e11b81526001600160a01b0383166004820152602401610351565b61031582610dbf565b5f6060805f5f5f60606107a5610e12565b6107ad610e3d565b604080515f80825260208201909252600f60f81b9b939a50919850469750309650945092509050565b5f8054600160a01b900460ff166107ec57505f90565b638fb3603760e01b5b905090565b61080333610304565b6108408383808060200260200160405190810160405280939291908181526020018383602002808284375f92019190915250859250610e68915050565b505050565b5f6107f561108e565b5f5f6108816108645f546001600160a01b031690565b863061087360045f898b611877565b61087c9161189e565b6111b7565b915091508161093d5763ffffffff81161561091a575f805460ff60a01b198116600160a01b17909155604051634a63ebf760e11b81526001600160a01b03909116906394c7d7ee906108db908890889088906004016118d6565b5f604051808303815f87803b1580156108f2575f5ffd5b505af1158015610904573d5f5f3e3d5ffd5b50505f805460ff60a01b191690555061093d9050565b60405162d1953b60e31b81526001600160a01b0386166004820152602401610351565b5050505050565b63ffffffff821615801590610961575061025863ffffffff831611155b8015610970575061ffff811615155b801561098257506101f461ffff821611155b828290916109b55760405163ad82b17760e01b815263ffffffff909216600483015261ffff166024820152604401610351565b50506005805466ffffffffffff00191661010063ffffffff851690810266ffff00000000001916919091176501000000000061ffff8516908102919091179092556040805191825260208201929092527fce44ae4eb3bc5a303e0bc68d713d264ec808b55560f90fc9d5b4888b347d26c8910160405180910390a15050565b5f80600481610a46602088018861164c565b6001600160a01b031681526020808201929092526040015f2054915081151590610a729087018761164c565b90610a9c57604051636bf4516160e11b81526001600160a01b039091166004820152602401610351565b50602085018035151590610ab0908761164c565b90610ada57604051634a6f5ccb60e01b81526001600160a01b039091166004820152602401610351565b5042610aec60608701604088016117fa565b6001600160401b03161115610b04602087018761164c565b610b1460608801604089016117fa565b42909192610b385760405163204cab6760e01b815260040161035193929190611915565b50859150610b4e905060608701604088016117fa565b6001600160401b03161015610b66602087018761164c565b610b7660608801604089016117fa565b86909192610b9a5760405163da56094f60e01b815260040161035193929190611915565b50849150610bb0905060608701604088016117fa565b6001600160401b031611610bc7602087018761164c565b610bd760608801604089016117fa565b85909192610bfb5760405163907f2a1360e01b815260040161035193929190611915565b505f9150610c6890507ff0a4e89bae3cce4cffe5c4c2423f4713b00c86897bd825ebcff34a4e1b4100b3886020890135610c3b60608b0160408c016117fa565b60408051602081019590955284019290925260608301526001600160401b0316608082015260a00161069d565b9050610c8d610c7a602088018861164c565b82610c8860608a018a61193f565b611249565b610c9a602088018861164c565b90610cc457604051633615713d60e21b81526001600160a01b039091166004820152602401610351565b50610cd06001836117b5565b6001901b979650505050505050565b815b5f81118015610d1257508184610cf86001846117b5565b81518110610d0857610d086117c8565b6020026020010151115b15610d685783610d236001836117b5565b81518110610d3357610d336117c8565b6020026020010151848281518110610d4d57610d4d6117c8565b6020908102919091010152610d6181611981565b9050610ce1565b81848281518110610d7b57610d7b6117c8565b60200260200101818152505050505050565b5f610db9610d9961108e565b8360405161190160f01b8152600281019290925260228201526042902090565b92915050565b5f80546001600160a01b0319166001600160a01b0383169081179091556040519081527f2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad9060200160405180910390a150565b60606107f57f00000000000000000000000000000000000000000000000000000000000000006112bb565b60606107f57f00000000000000000000000000000000000000000000000000000000000000006112bb565b81518015801590610e7a575060108111155b8190610e9c576040516307f6043b60e41b815260040161035191815260200190565b5060028260ff1610158015610eb45750808260ff1611155b82829091610ee05760405163830287af60e01b815260ff90921660048301526024820152604401610351565b50506003545f5b81811015610f315760045f60038381548110610f0557610f056117c8565b5f9182526020808320909101546001600160a01b03168352820192909252604001812055600101610ee7565b50610f3d60035f611498565b5f5b8281101561103e575f858281518110610f5a57610f5a6117c8565b602002602001015190505f6001600160a01b0316816001600160a01b031614158015610f9b57506001600160a01b0381165f90815260046020526040902054155b8190610fc65760405163311afa8f60e01b81526001600160a01b039091166004820152602401610351565b5060038054600180820183555f929092527fc2575a0e9e593c00f959f8c92f12db2869c3395a3b0502d05e2516446f71f85b0180546001600160a01b0319166001600160a01b03841617905561101d90839061184d565b6001600160a01b039091165f90815260046020526040902055600101610f3f565b506005805460ff191660ff85161790556040517f77ab1b4817128e6561abaf5f56ed3393a4032181938849f5ff1277e2583413a0906110809086908690611996565b60405180910390a150505050565b5f306001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000161480156110e657507f000000000000000000000000000000000000000000000000000000000000000046145b1561111057507f000000000000000000000000000000000000000000000000000000000000000090565b6107f5604080517f8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f60208201527f0000000000000000000000000000000000000000000000000000000000000000918101919091527f000000000000000000000000000000000000000000000000000000000000000060608201524660808201523060a08201525f9060c00160405160208183030381529060405280519060200120905090565b6040516001600160a01b038085166024830152831660448201526001600160e01b0319821660648201525f908190819060840160408051601f19818403018152918152602080830180516001600160e01b031663b700961360e01b1781525f808052918290528351939450919290918a5afa1561123f575f516020805191945081901c150291505b5094509492505050565b5f846001600160a01b03163b5f036112a8575f5f6112688686866112f8565b5090925090505f816003811115611281576112816119ba565b14801561129f5750866001600160a01b0316826001600160a01b0316145b925050506106b8565b6112b48585858561133f565b90506106b8565b60605f6112c7836113a9565b6040805160208082528183019092529192505f91906020820181803683375050509182525060208101929092525090565b5f8080604184900361132c578435602086013560408701355f1a61131e898285856113d0565b955095509550505050611336565b505f915060029050825b93509350939050565b60408051630b135d3f60e11b808252600482018690526024820192909252604481018390525f91908390818660648301375f82606483010152601f820160051c60051b915060205f60648401838b5afa9050825f5114601f3d111681169350505050949350505050565b5f60ff8216601f811115610db957604051632cd44ac360e21b815260040160405180910390fd5b5f80807f7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a084111561140957505f9150600390508261148e565b604080515f808252602082018084528a905260ff891692820192909252606081018790526080810186905260019060a0016020604051602081039080840390855afa15801561145a573d5f5f3e3d5ffd5b5050604051601f1901519150506001600160a01b03811661148557505f92506001915082905061148e565b92505f91508190505b9450945094915050565b5080545f8255905f5260205f20906114b091906114b2565b565b5f5b80821115610840575f818401556001016114b4565b5f5f604083850312156114da575f5ffd5b823563ffffffff811681146114ed575f5ffd5b9150602083013561ffff81168114611503575f5ffd5b809150509250929050565b5f5f83601f84011261151e575f5ffd5b5081356001600160401b03811115611534575f5ffd5b6020830191508360208260051b850101111561154e575f5ffd5b9250929050565b5f5f5f5f60608587031215611568575f5ffd5b8435935060208501356001600160401b03811115611584575f5ffd5b6115908782880161150e565b9598909750949560400135949350505050565b80356001600160401b03811681146115b9575f5ffd5b919050565b5f5f5f606084860312156115d0575f5ffd5b83359250602084013591506115e7604085016115a3565b90509250925092565b5f8151808452602084019350602083015f5b828110156116295781516001600160a01b0316865260209586019590910190600101611602565b5093949350505050565b602081525f61164560208301846115f0565b9392505050565b5f6020828403121561165c575f5ffd5b81356001600160a01b0381168114611645575f5ffd5b5f81518084528060208401602086015e5f602082860101526020601f19601f83011685010191505092915050565b60ff60f81b8816815260e060208201525f6116be60e0830189611672565b82810360408401526116d08189611672565b606084018890526001600160a01b038716608085015260a0840186905283810360c0850152845180825260208087019350909101905f5b81811015611725578351835260209384019390920191600101611707565b50909b9a5050505050505050505050565b5f5f5f60408486031215611748575f5ffd5b83356001600160401b0381111561175d575f5ffd5b6117698682870161150e565b909450925050602084013560ff81168114611782575f5ffd5b809150509250925092565b634e487b7160e01b5f52604160045260245ffd5b634e487b7160e01b5f52601160045260245ffd5b81810381811115610db957610db96117a1565b634e487b7160e01b5f52603260045260245ffd5b5f8235607e198336030181126117f0575f5ffd5b9190910192915050565b5f6020828403121561180a575f5ffd5b611645826115a3565b634e487b7160e01b5f52601260045260245ffd5b5f8261183557611835611813565b500490565b5f8261184857611848611813565b500690565b80820180821115610db957610db96117a1565b8082028115828204841417610db957610db96117a1565b5f5f85851115611885575f5ffd5b83861115611891575f5ffd5b5050820193919092039150565b80356001600160e01b031981169060048410156118cf576001600160e01b0319600485900360031b81901b82161691505b5092915050565b6001600160a01b03841681526040602082018190528101829052818360608301375f818301606090810191909152601f909201601f1916010192915050565b6001600160a01b039390931683526001600160401b03919091166020830152604082015260600190565b5f5f8335601e19843603018112611954575f5ffd5b8301803591506001600160401b0382111561196d575f5ffd5b60200191503681900382131561154e575f5ffd5b5f8161198f5761198f6117a1565b505f190190565b604081525f6119a860408301856115f0565b905060ff831660208301529392505050565b634e487b7160e01b5f52602160045260245ffd",
}

// OracleVerifierABI is the input ABI used to generate the binding from.
// Deprecated: Use OracleVerifierMetaData.ABI instead.
var OracleVerifierABI = OracleVerifierMetaData.ABI

// OracleVerifierBin is the compiled bytecode used for deploying new contracts.
// Deprecated: Use OracleVerifierMetaData.Bin instead.
var OracleVerifierBin = OracleVerifierMetaData.Bin

// DeployOracleVerifier deploys a new Ethereum contract, binding an instance of OracleVerifier to it.
func DeployOracleVerifier(auth *bind.TransactOpts, backend bind.ContractBackend, authority_ common.Address, initialSigners []common.Address, initialMinSigners uint8, initialMaxReportAge uint32, initialMaxSpreadBps uint16) (common.Address, *types.Transaction, *OracleVerifier, error) {
	parsed, err := OracleVerifierMetaData.GetAbi()
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	if parsed == nil {
		return common.Address{}, nil, nil, errors.New("GetABI returned nil")
	}

	address, tx, contract, err := bind.DeployContract(auth, *parsed, common.FromHex(OracleVerifierBin), backend, authority_, initialSigners, initialMinSigners, initialMaxReportAge, initialMaxSpreadBps)
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	return address, tx, &OracleVerifier{OracleVerifierCaller: OracleVerifierCaller{contract: contract}, OracleVerifierTransactor: OracleVerifierTransactor{contract: contract}, OracleVerifierFilterer: OracleVerifierFilterer{contract: contract}}, nil
}

// OracleVerifier is an auto generated Go binding around an Ethereum contract.
type OracleVerifier struct {
	OracleVerifierCaller     // Read-only binding to the contract
	OracleVerifierTransactor // Write-only binding to the contract
	OracleVerifierFilterer   // Log filterer for contract events
}

// OracleVerifierCaller is an auto generated read-only Go binding around an Ethereum contract.
type OracleVerifierCaller struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// OracleVerifierTransactor is an auto generated write-only Go binding around an Ethereum contract.
type OracleVerifierTransactor struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// OracleVerifierFilterer is an auto generated log filtering Go binding around an Ethereum contract events.
type OracleVerifierFilterer struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// OracleVerifierSession is an auto generated Go binding around an Ethereum contract,
// with pre-set call and transact options.
type OracleVerifierSession struct {
	Contract     *OracleVerifier   // Generic contract binding to set the session for
	CallOpts     bind.CallOpts     // Call options to use throughout this session
	TransactOpts bind.TransactOpts // Transaction auth options to use throughout this session
}

// OracleVerifierCallerSession is an auto generated read-only Go binding around an Ethereum contract,
// with pre-set call options.
type OracleVerifierCallerSession struct {
	Contract *OracleVerifierCaller // Generic contract caller binding to set the session for
	CallOpts bind.CallOpts         // Call options to use throughout this session
}

// OracleVerifierTransactorSession is an auto generated write-only Go binding around an Ethereum contract,
// with pre-set transact options.
type OracleVerifierTransactorSession struct {
	Contract     *OracleVerifierTransactor // Generic contract transactor binding to set the session for
	TransactOpts bind.TransactOpts         // Transaction auth options to use throughout this session
}

// OracleVerifierRaw is an auto generated low-level Go binding around an Ethereum contract.
type OracleVerifierRaw struct {
	Contract *OracleVerifier // Generic contract binding to access the raw methods on
}

// OracleVerifierCallerRaw is an auto generated low-level read-only Go binding around an Ethereum contract.
type OracleVerifierCallerRaw struct {
	Contract *OracleVerifierCaller // Generic read-only contract binding to access the raw methods on
}

// OracleVerifierTransactorRaw is an auto generated low-level write-only Go binding around an Ethereum contract.
type OracleVerifierTransactorRaw struct {
	Contract *OracleVerifierTransactor // Generic write-only contract binding to access the raw methods on
}

// NewOracleVerifier creates a new instance of OracleVerifier, bound to a specific deployed contract.
func NewOracleVerifier(address common.Address, backend bind.ContractBackend) (*OracleVerifier, error) {
	contract, err := bindOracleVerifier(address, backend, backend, backend)
	if err != nil {
		return nil, err
	}
	return &OracleVerifier{OracleVerifierCaller: OracleVerifierCaller{contract: contract}, OracleVerifierTransactor: OracleVerifierTransactor{contract: contract}, OracleVerifierFilterer: OracleVerifierFilterer{contract: contract}}, nil
}

// NewOracleVerifierCaller creates a new read-only instance of OracleVerifier, bound to a specific deployed contract.
func NewOracleVerifierCaller(address common.Address, caller bind.ContractCaller) (*OracleVerifierCaller, error) {
	contract, err := bindOracleVerifier(address, caller, nil, nil)
	if err != nil {
		return nil, err
	}
	return &OracleVerifierCaller{contract: contract}, nil
}

// NewOracleVerifierTransactor creates a new write-only instance of OracleVerifier, bound to a specific deployed contract.
func NewOracleVerifierTransactor(address common.Address, transactor bind.ContractTransactor) (*OracleVerifierTransactor, error) {
	contract, err := bindOracleVerifier(address, nil, transactor, nil)
	if err != nil {
		return nil, err
	}
	return &OracleVerifierTransactor{contract: contract}, nil
}

// NewOracleVerifierFilterer creates a new log filterer instance of OracleVerifier, bound to a specific deployed contract.
func NewOracleVerifierFilterer(address common.Address, filterer bind.ContractFilterer) (*OracleVerifierFilterer, error) {
	contract, err := bindOracleVerifier(address, nil, nil, filterer)
	if err != nil {
		return nil, err
	}
	return &OracleVerifierFilterer{contract: contract}, nil
}

// bindOracleVerifier binds a generic wrapper to an already deployed contract.
func bindOracleVerifier(address common.Address, caller bind.ContractCaller, transactor bind.ContractTransactor, filterer bind.ContractFilterer) (*bind.BoundContract, error) {
	parsed, err := OracleVerifierMetaData.GetAbi()
	if err != nil {
		return nil, err
	}
	return bind.NewBoundContract(address, *parsed, caller, transactor, filterer), nil
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_OracleVerifier *OracleVerifierRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _OracleVerifier.Contract.OracleVerifierCaller.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_OracleVerifier *OracleVerifierRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _OracleVerifier.Contract.OracleVerifierTransactor.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_OracleVerifier *OracleVerifierRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _OracleVerifier.Contract.OracleVerifierTransactor.contract.Transact(opts, method, params...)
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_OracleVerifier *OracleVerifierCallerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _OracleVerifier.Contract.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_OracleVerifier *OracleVerifierTransactorRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _OracleVerifier.Contract.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_OracleVerifier *OracleVerifierTransactorRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _OracleVerifier.Contract.contract.Transact(opts, method, params...)
}

// MAXREPORTAGELIMIT is a free data retrieval call binding the contract method 0x8c756a40.
//
// Solidity: function MAX_REPORT_AGE_LIMIT() view returns(uint32)
func (_OracleVerifier *OracleVerifierCaller) MAXREPORTAGELIMIT(opts *bind.CallOpts) (uint32, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "MAX_REPORT_AGE_LIMIT")

	if err != nil {
		return *new(uint32), err
	}

	out0 := *abi.ConvertType(out[0], new(uint32)).(*uint32)

	return out0, err

}

// MAXREPORTAGELIMIT is a free data retrieval call binding the contract method 0x8c756a40.
//
// Solidity: function MAX_REPORT_AGE_LIMIT() view returns(uint32)
func (_OracleVerifier *OracleVerifierSession) MAXREPORTAGELIMIT() (uint32, error) {
	return _OracleVerifier.Contract.MAXREPORTAGELIMIT(&_OracleVerifier.CallOpts)
}

// MAXREPORTAGELIMIT is a free data retrieval call binding the contract method 0x8c756a40.
//
// Solidity: function MAX_REPORT_AGE_LIMIT() view returns(uint32)
func (_OracleVerifier *OracleVerifierCallerSession) MAXREPORTAGELIMIT() (uint32, error) {
	return _OracleVerifier.Contract.MAXREPORTAGELIMIT(&_OracleVerifier.CallOpts)
}

// MAXSIGNERS is a free data retrieval call binding the contract method 0x59ecd657.
//
// Solidity: function MAX_SIGNERS() view returns(uint256)
func (_OracleVerifier *OracleVerifierCaller) MAXSIGNERS(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "MAX_SIGNERS")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// MAXSIGNERS is a free data retrieval call binding the contract method 0x59ecd657.
//
// Solidity: function MAX_SIGNERS() view returns(uint256)
func (_OracleVerifier *OracleVerifierSession) MAXSIGNERS() (*big.Int, error) {
	return _OracleVerifier.Contract.MAXSIGNERS(&_OracleVerifier.CallOpts)
}

// MAXSIGNERS is a free data retrieval call binding the contract method 0x59ecd657.
//
// Solidity: function MAX_SIGNERS() view returns(uint256)
func (_OracleVerifier *OracleVerifierCallerSession) MAXSIGNERS() (*big.Int, error) {
	return _OracleVerifier.Contract.MAXSIGNERS(&_OracleVerifier.CallOpts)
}

// MAXSPREADLIMITBPS is a free data retrieval call binding the contract method 0x28726083.
//
// Solidity: function MAX_SPREAD_LIMIT_BPS() view returns(uint16)
func (_OracleVerifier *OracleVerifierCaller) MAXSPREADLIMITBPS(opts *bind.CallOpts) (uint16, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "MAX_SPREAD_LIMIT_BPS")

	if err != nil {
		return *new(uint16), err
	}

	out0 := *abi.ConvertType(out[0], new(uint16)).(*uint16)

	return out0, err

}

// MAXSPREADLIMITBPS is a free data retrieval call binding the contract method 0x28726083.
//
// Solidity: function MAX_SPREAD_LIMIT_BPS() view returns(uint16)
func (_OracleVerifier *OracleVerifierSession) MAXSPREADLIMITBPS() (uint16, error) {
	return _OracleVerifier.Contract.MAXSPREADLIMITBPS(&_OracleVerifier.CallOpts)
}

// MAXSPREADLIMITBPS is a free data retrieval call binding the contract method 0x28726083.
//
// Solidity: function MAX_SPREAD_LIMIT_BPS() view returns(uint16)
func (_OracleVerifier *OracleVerifierCallerSession) MAXSPREADLIMITBPS() (uint16, error) {
	return _OracleVerifier.Contract.MAXSPREADLIMITBPS(&_OracleVerifier.CallOpts)
}

// PRICEREPORTTYPEHASH is a free data retrieval call binding the contract method 0xae3c9941.
//
// Solidity: function PRICE_REPORT_TYPEHASH() view returns(bytes32)
func (_OracleVerifier *OracleVerifierCaller) PRICEREPORTTYPEHASH(opts *bind.CallOpts) ([32]byte, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "PRICE_REPORT_TYPEHASH")

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// PRICEREPORTTYPEHASH is a free data retrieval call binding the contract method 0xae3c9941.
//
// Solidity: function PRICE_REPORT_TYPEHASH() view returns(bytes32)
func (_OracleVerifier *OracleVerifierSession) PRICEREPORTTYPEHASH() ([32]byte, error) {
	return _OracleVerifier.Contract.PRICEREPORTTYPEHASH(&_OracleVerifier.CallOpts)
}

// PRICEREPORTTYPEHASH is a free data retrieval call binding the contract method 0xae3c9941.
//
// Solidity: function PRICE_REPORT_TYPEHASH() view returns(bytes32)
func (_OracleVerifier *OracleVerifierCallerSession) PRICEREPORTTYPEHASH() ([32]byte, error) {
	return _OracleVerifier.Contract.PRICEREPORTTYPEHASH(&_OracleVerifier.CallOpts)
}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_OracleVerifier *OracleVerifierCaller) Authority(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "authority")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_OracleVerifier *OracleVerifierSession) Authority() (common.Address, error) {
	return _OracleVerifier.Contract.Authority(&_OracleVerifier.CallOpts)
}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_OracleVerifier *OracleVerifierCallerSession) Authority() (common.Address, error) {
	return _OracleVerifier.Contract.Authority(&_OracleVerifier.CallOpts)
}

// DomainSeparator is a free data retrieval call binding the contract method 0xf698da25.
//
// Solidity: function domainSeparator() view returns(bytes32)
func (_OracleVerifier *OracleVerifierCaller) DomainSeparator(opts *bind.CallOpts) ([32]byte, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "domainSeparator")

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// DomainSeparator is a free data retrieval call binding the contract method 0xf698da25.
//
// Solidity: function domainSeparator() view returns(bytes32)
func (_OracleVerifier *OracleVerifierSession) DomainSeparator() ([32]byte, error) {
	return _OracleVerifier.Contract.DomainSeparator(&_OracleVerifier.CallOpts)
}

// DomainSeparator is a free data retrieval call binding the contract method 0xf698da25.
//
// Solidity: function domainSeparator() view returns(bytes32)
func (_OracleVerifier *OracleVerifierCallerSession) DomainSeparator() ([32]byte, error) {
	return _OracleVerifier.Contract.DomainSeparator(&_OracleVerifier.CallOpts)
}

// Eip712Domain is a free data retrieval call binding the contract method 0x84b0196e.
//
// Solidity: function eip712Domain() view returns(bytes1 fields, string name, string version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] extensions)
func (_OracleVerifier *OracleVerifierCaller) Eip712Domain(opts *bind.CallOpts) (struct {
	Fields            [1]byte
	Name              string
	Version           string
	ChainId           *big.Int
	VerifyingContract common.Address
	Salt              [32]byte
	Extensions        []*big.Int
}, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "eip712Domain")

	outstruct := new(struct {
		Fields            [1]byte
		Name              string
		Version           string
		ChainId           *big.Int
		VerifyingContract common.Address
		Salt              [32]byte
		Extensions        []*big.Int
	})
	if err != nil {
		return *outstruct, err
	}

	outstruct.Fields = *abi.ConvertType(out[0], new([1]byte)).(*[1]byte)
	outstruct.Name = *abi.ConvertType(out[1], new(string)).(*string)
	outstruct.Version = *abi.ConvertType(out[2], new(string)).(*string)
	outstruct.ChainId = *abi.ConvertType(out[3], new(*big.Int)).(**big.Int)
	outstruct.VerifyingContract = *abi.ConvertType(out[4], new(common.Address)).(*common.Address)
	outstruct.Salt = *abi.ConvertType(out[5], new([32]byte)).(*[32]byte)
	outstruct.Extensions = *abi.ConvertType(out[6], new([]*big.Int)).(*[]*big.Int)

	return *outstruct, err

}

// Eip712Domain is a free data retrieval call binding the contract method 0x84b0196e.
//
// Solidity: function eip712Domain() view returns(bytes1 fields, string name, string version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] extensions)
func (_OracleVerifier *OracleVerifierSession) Eip712Domain() (struct {
	Fields            [1]byte
	Name              string
	Version           string
	ChainId           *big.Int
	VerifyingContract common.Address
	Salt              [32]byte
	Extensions        []*big.Int
}, error) {
	return _OracleVerifier.Contract.Eip712Domain(&_OracleVerifier.CallOpts)
}

// Eip712Domain is a free data retrieval call binding the contract method 0x84b0196e.
//
// Solidity: function eip712Domain() view returns(bytes1 fields, string name, string version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] extensions)
func (_OracleVerifier *OracleVerifierCallerSession) Eip712Domain() (struct {
	Fields            [1]byte
	Name              string
	Version           string
	ChainId           *big.Int
	VerifyingContract common.Address
	Salt              [32]byte
	Extensions        []*big.Int
}, error) {
	return _OracleVerifier.Contract.Eip712Domain(&_OracleVerifier.CallOpts)
}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_OracleVerifier *OracleVerifierCaller) IsConsumingScheduledOp(opts *bind.CallOpts) ([4]byte, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "isConsumingScheduledOp")

	if err != nil {
		return *new([4]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([4]byte)).(*[4]byte)

	return out0, err

}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_OracleVerifier *OracleVerifierSession) IsConsumingScheduledOp() ([4]byte, error) {
	return _OracleVerifier.Contract.IsConsumingScheduledOp(&_OracleVerifier.CallOpts)
}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_OracleVerifier *OracleVerifierCallerSession) IsConsumingScheduledOp() ([4]byte, error) {
	return _OracleVerifier.Contract.IsConsumingScheduledOp(&_OracleVerifier.CallOpts)
}

// IsSigner is a free data retrieval call binding the contract method 0x7df73e27.
//
// Solidity: function isSigner(address account) view returns(bool)
func (_OracleVerifier *OracleVerifierCaller) IsSigner(opts *bind.CallOpts, account common.Address) (bool, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "isSigner", account)

	if err != nil {
		return *new(bool), err
	}

	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)

	return out0, err

}

// IsSigner is a free data retrieval call binding the contract method 0x7df73e27.
//
// Solidity: function isSigner(address account) view returns(bool)
func (_OracleVerifier *OracleVerifierSession) IsSigner(account common.Address) (bool, error) {
	return _OracleVerifier.Contract.IsSigner(&_OracleVerifier.CallOpts, account)
}

// IsSigner is a free data retrieval call binding the contract method 0x7df73e27.
//
// Solidity: function isSigner(address account) view returns(bool)
func (_OracleVerifier *OracleVerifierCallerSession) IsSigner(account common.Address) (bool, error) {
	return _OracleVerifier.Contract.IsSigner(&_OracleVerifier.CallOpts, account)
}

// MaxReportAge is a free data retrieval call binding the contract method 0xc45e0d24.
//
// Solidity: function maxReportAge() view returns(uint32)
func (_OracleVerifier *OracleVerifierCaller) MaxReportAge(opts *bind.CallOpts) (uint32, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "maxReportAge")

	if err != nil {
		return *new(uint32), err
	}

	out0 := *abi.ConvertType(out[0], new(uint32)).(*uint32)

	return out0, err

}

// MaxReportAge is a free data retrieval call binding the contract method 0xc45e0d24.
//
// Solidity: function maxReportAge() view returns(uint32)
func (_OracleVerifier *OracleVerifierSession) MaxReportAge() (uint32, error) {
	return _OracleVerifier.Contract.MaxReportAge(&_OracleVerifier.CallOpts)
}

// MaxReportAge is a free data retrieval call binding the contract method 0xc45e0d24.
//
// Solidity: function maxReportAge() view returns(uint32)
func (_OracleVerifier *OracleVerifierCallerSession) MaxReportAge() (uint32, error) {
	return _OracleVerifier.Contract.MaxReportAge(&_OracleVerifier.CallOpts)
}

// MaxSpreadBps is a free data retrieval call binding the contract method 0xc0afe83b.
//
// Solidity: function maxSpreadBps() view returns(uint16)
func (_OracleVerifier *OracleVerifierCaller) MaxSpreadBps(opts *bind.CallOpts) (uint16, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "maxSpreadBps")

	if err != nil {
		return *new(uint16), err
	}

	out0 := *abi.ConvertType(out[0], new(uint16)).(*uint16)

	return out0, err

}

// MaxSpreadBps is a free data retrieval call binding the contract method 0xc0afe83b.
//
// Solidity: function maxSpreadBps() view returns(uint16)
func (_OracleVerifier *OracleVerifierSession) MaxSpreadBps() (uint16, error) {
	return _OracleVerifier.Contract.MaxSpreadBps(&_OracleVerifier.CallOpts)
}

// MaxSpreadBps is a free data retrieval call binding the contract method 0xc0afe83b.
//
// Solidity: function maxSpreadBps() view returns(uint16)
func (_OracleVerifier *OracleVerifierCallerSession) MaxSpreadBps() (uint16, error) {
	return _OracleVerifier.Contract.MaxSpreadBps(&_OracleVerifier.CallOpts)
}

// MinSigners is a free data retrieval call binding the contract method 0xb70f7e84.
//
// Solidity: function minSigners() view returns(uint8)
func (_OracleVerifier *OracleVerifierCaller) MinSigners(opts *bind.CallOpts) (uint8, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "minSigners")

	if err != nil {
		return *new(uint8), err
	}

	out0 := *abi.ConvertType(out[0], new(uint8)).(*uint8)

	return out0, err

}

// MinSigners is a free data retrieval call binding the contract method 0xb70f7e84.
//
// Solidity: function minSigners() view returns(uint8)
func (_OracleVerifier *OracleVerifierSession) MinSigners() (uint8, error) {
	return _OracleVerifier.Contract.MinSigners(&_OracleVerifier.CallOpts)
}

// MinSigners is a free data retrieval call binding the contract method 0xb70f7e84.
//
// Solidity: function minSigners() view returns(uint8)
func (_OracleVerifier *OracleVerifierCallerSession) MinSigners() (uint8, error) {
	return _OracleVerifier.Contract.MinSigners(&_OracleVerifier.CallOpts)
}

// ReportDigest is a free data retrieval call binding the contract method 0x2b53933a.
//
// Solidity: function reportDigest(bytes32 marketId, uint256 price, uint64 timestamp) view returns(bytes32)
func (_OracleVerifier *OracleVerifierCaller) ReportDigest(opts *bind.CallOpts, marketId [32]byte, price *big.Int, timestamp uint64) ([32]byte, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "reportDigest", marketId, price, timestamp)

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// ReportDigest is a free data retrieval call binding the contract method 0x2b53933a.
//
// Solidity: function reportDigest(bytes32 marketId, uint256 price, uint64 timestamp) view returns(bytes32)
func (_OracleVerifier *OracleVerifierSession) ReportDigest(marketId [32]byte, price *big.Int, timestamp uint64) ([32]byte, error) {
	return _OracleVerifier.Contract.ReportDigest(&_OracleVerifier.CallOpts, marketId, price, timestamp)
}

// ReportDigest is a free data retrieval call binding the contract method 0x2b53933a.
//
// Solidity: function reportDigest(bytes32 marketId, uint256 price, uint64 timestamp) view returns(bytes32)
func (_OracleVerifier *OracleVerifierCallerSession) ReportDigest(marketId [32]byte, price *big.Int, timestamp uint64) ([32]byte, error) {
	return _OracleVerifier.Contract.ReportDigest(&_OracleVerifier.CallOpts, marketId, price, timestamp)
}

// Signers is a free data retrieval call binding the contract method 0x46f0975a.
//
// Solidity: function signers() view returns(address[])
func (_OracleVerifier *OracleVerifierCaller) Signers(opts *bind.CallOpts) ([]common.Address, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "signers")

	if err != nil {
		return *new([]common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new([]common.Address)).(*[]common.Address)

	return out0, err

}

// Signers is a free data retrieval call binding the contract method 0x46f0975a.
//
// Solidity: function signers() view returns(address[])
func (_OracleVerifier *OracleVerifierSession) Signers() ([]common.Address, error) {
	return _OracleVerifier.Contract.Signers(&_OracleVerifier.CallOpts)
}

// Signers is a free data retrieval call binding the contract method 0x46f0975a.
//
// Solidity: function signers() view returns(address[])
func (_OracleVerifier *OracleVerifierCallerSession) Signers() ([]common.Address, error) {
	return _OracleVerifier.Contract.Signers(&_OracleVerifier.CallOpts)
}

// VerifyReports is a free data retrieval call binding the contract method 0x27552f6d.
//
// Solidity: function verifyReports(bytes32 marketId, (address,uint256,uint64,bytes)[] reports, uint256 requestTimestamp) view returns(uint256 medianPrice, uint256 oldestTimestamp)
func (_OracleVerifier *OracleVerifierCaller) VerifyReports(opts *bind.CallOpts, marketId [32]byte, reports []IOracleVerifierSignedPriceReport, requestTimestamp *big.Int) (struct {
	MedianPrice     *big.Int
	OldestTimestamp *big.Int
}, error) {
	var out []interface{}
	err := _OracleVerifier.contract.Call(opts, &out, "verifyReports", marketId, reports, requestTimestamp)

	outstruct := new(struct {
		MedianPrice     *big.Int
		OldestTimestamp *big.Int
	})
	if err != nil {
		return *outstruct, err
	}

	outstruct.MedianPrice = *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)
	outstruct.OldestTimestamp = *abi.ConvertType(out[1], new(*big.Int)).(**big.Int)

	return *outstruct, err

}

// VerifyReports is a free data retrieval call binding the contract method 0x27552f6d.
//
// Solidity: function verifyReports(bytes32 marketId, (address,uint256,uint64,bytes)[] reports, uint256 requestTimestamp) view returns(uint256 medianPrice, uint256 oldestTimestamp)
func (_OracleVerifier *OracleVerifierSession) VerifyReports(marketId [32]byte, reports []IOracleVerifierSignedPriceReport, requestTimestamp *big.Int) (struct {
	MedianPrice     *big.Int
	OldestTimestamp *big.Int
}, error) {
	return _OracleVerifier.Contract.VerifyReports(&_OracleVerifier.CallOpts, marketId, reports, requestTimestamp)
}

// VerifyReports is a free data retrieval call binding the contract method 0x27552f6d.
//
// Solidity: function verifyReports(bytes32 marketId, (address,uint256,uint64,bytes)[] reports, uint256 requestTimestamp) view returns(uint256 medianPrice, uint256 oldestTimestamp)
func (_OracleVerifier *OracleVerifierCallerSession) VerifyReports(marketId [32]byte, reports []IOracleVerifierSignedPriceReport, requestTimestamp *big.Int) (struct {
	MedianPrice     *big.Int
	OldestTimestamp *big.Int
}, error) {
	return _OracleVerifier.Contract.VerifyReports(&_OracleVerifier.CallOpts, marketId, reports, requestTimestamp)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_OracleVerifier *OracleVerifierTransactor) SetAuthority(opts *bind.TransactOpts, newAuthority common.Address) (*types.Transaction, error) {
	return _OracleVerifier.contract.Transact(opts, "setAuthority", newAuthority)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_OracleVerifier *OracleVerifierSession) SetAuthority(newAuthority common.Address) (*types.Transaction, error) {
	return _OracleVerifier.Contract.SetAuthority(&_OracleVerifier.TransactOpts, newAuthority)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_OracleVerifier *OracleVerifierTransactorSession) SetAuthority(newAuthority common.Address) (*types.Transaction, error) {
	return _OracleVerifier.Contract.SetAuthority(&_OracleVerifier.TransactOpts, newAuthority)
}

// SetReportLimits is a paid mutator transaction binding the contract method 0x1d5b02ba.
//
// Solidity: function setReportLimits(uint32 newMaxReportAge, uint16 newMaxSpreadBps) returns()
func (_OracleVerifier *OracleVerifierTransactor) SetReportLimits(opts *bind.TransactOpts, newMaxReportAge uint32, newMaxSpreadBps uint16) (*types.Transaction, error) {
	return _OracleVerifier.contract.Transact(opts, "setReportLimits", newMaxReportAge, newMaxSpreadBps)
}

// SetReportLimits is a paid mutator transaction binding the contract method 0x1d5b02ba.
//
// Solidity: function setReportLimits(uint32 newMaxReportAge, uint16 newMaxSpreadBps) returns()
func (_OracleVerifier *OracleVerifierSession) SetReportLimits(newMaxReportAge uint32, newMaxSpreadBps uint16) (*types.Transaction, error) {
	return _OracleVerifier.Contract.SetReportLimits(&_OracleVerifier.TransactOpts, newMaxReportAge, newMaxSpreadBps)
}

// SetReportLimits is a paid mutator transaction binding the contract method 0x1d5b02ba.
//
// Solidity: function setReportLimits(uint32 newMaxReportAge, uint16 newMaxSpreadBps) returns()
func (_OracleVerifier *OracleVerifierTransactorSession) SetReportLimits(newMaxReportAge uint32, newMaxSpreadBps uint16) (*types.Transaction, error) {
	return _OracleVerifier.Contract.SetReportLimits(&_OracleVerifier.TransactOpts, newMaxReportAge, newMaxSpreadBps)
}

// SetSigners is a paid mutator transaction binding the contract method 0xdaf3f08b.
//
// Solidity: function setSigners(address[] newSigners, uint8 newMinSigners) returns()
func (_OracleVerifier *OracleVerifierTransactor) SetSigners(opts *bind.TransactOpts, newSigners []common.Address, newMinSigners uint8) (*types.Transaction, error) {
	return _OracleVerifier.contract.Transact(opts, "setSigners", newSigners, newMinSigners)
}

// SetSigners is a paid mutator transaction binding the contract method 0xdaf3f08b.
//
// Solidity: function setSigners(address[] newSigners, uint8 newMinSigners) returns()
func (_OracleVerifier *OracleVerifierSession) SetSigners(newSigners []common.Address, newMinSigners uint8) (*types.Transaction, error) {
	return _OracleVerifier.Contract.SetSigners(&_OracleVerifier.TransactOpts, newSigners, newMinSigners)
}

// SetSigners is a paid mutator transaction binding the contract method 0xdaf3f08b.
//
// Solidity: function setSigners(address[] newSigners, uint8 newMinSigners) returns()
func (_OracleVerifier *OracleVerifierTransactorSession) SetSigners(newSigners []common.Address, newMinSigners uint8) (*types.Transaction, error) {
	return _OracleVerifier.Contract.SetSigners(&_OracleVerifier.TransactOpts, newSigners, newMinSigners)
}

// OracleVerifierAuthorityUpdatedIterator is returned from FilterAuthorityUpdated and is used to iterate over the raw logs and unpacked data for AuthorityUpdated events raised by the OracleVerifier contract.
type OracleVerifierAuthorityUpdatedIterator struct {
	Event *OracleVerifierAuthorityUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *OracleVerifierAuthorityUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(OracleVerifierAuthorityUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(OracleVerifierAuthorityUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *OracleVerifierAuthorityUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *OracleVerifierAuthorityUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// OracleVerifierAuthorityUpdated represents a AuthorityUpdated event raised by the OracleVerifier contract.
type OracleVerifierAuthorityUpdated struct {
	Authority common.Address
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterAuthorityUpdated is a free log retrieval operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_OracleVerifier *OracleVerifierFilterer) FilterAuthorityUpdated(opts *bind.FilterOpts) (*OracleVerifierAuthorityUpdatedIterator, error) {

	logs, sub, err := _OracleVerifier.contract.FilterLogs(opts, "AuthorityUpdated")
	if err != nil {
		return nil, err
	}
	return &OracleVerifierAuthorityUpdatedIterator{contract: _OracleVerifier.contract, event: "AuthorityUpdated", logs: logs, sub: sub}, nil
}

// WatchAuthorityUpdated is a free log subscription operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_OracleVerifier *OracleVerifierFilterer) WatchAuthorityUpdated(opts *bind.WatchOpts, sink chan<- *OracleVerifierAuthorityUpdated) (event.Subscription, error) {

	logs, sub, err := _OracleVerifier.contract.WatchLogs(opts, "AuthorityUpdated")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(OracleVerifierAuthorityUpdated)
				if err := _OracleVerifier.contract.UnpackLog(event, "AuthorityUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseAuthorityUpdated is a log parse operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_OracleVerifier *OracleVerifierFilterer) ParseAuthorityUpdated(log types.Log) (*OracleVerifierAuthorityUpdated, error) {
	event := new(OracleVerifierAuthorityUpdated)
	if err := _OracleVerifier.contract.UnpackLog(event, "AuthorityUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// OracleVerifierEIP712DomainChangedIterator is returned from FilterEIP712DomainChanged and is used to iterate over the raw logs and unpacked data for EIP712DomainChanged events raised by the OracleVerifier contract.
type OracleVerifierEIP712DomainChangedIterator struct {
	Event *OracleVerifierEIP712DomainChanged // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *OracleVerifierEIP712DomainChangedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(OracleVerifierEIP712DomainChanged)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(OracleVerifierEIP712DomainChanged)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *OracleVerifierEIP712DomainChangedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *OracleVerifierEIP712DomainChangedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// OracleVerifierEIP712DomainChanged represents a EIP712DomainChanged event raised by the OracleVerifier contract.
type OracleVerifierEIP712DomainChanged struct {
	Raw types.Log // Blockchain specific contextual infos
}

// FilterEIP712DomainChanged is a free log retrieval operation binding the contract event 0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31.
//
// Solidity: event EIP712DomainChanged()
func (_OracleVerifier *OracleVerifierFilterer) FilterEIP712DomainChanged(opts *bind.FilterOpts) (*OracleVerifierEIP712DomainChangedIterator, error) {

	logs, sub, err := _OracleVerifier.contract.FilterLogs(opts, "EIP712DomainChanged")
	if err != nil {
		return nil, err
	}
	return &OracleVerifierEIP712DomainChangedIterator{contract: _OracleVerifier.contract, event: "EIP712DomainChanged", logs: logs, sub: sub}, nil
}

// WatchEIP712DomainChanged is a free log subscription operation binding the contract event 0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31.
//
// Solidity: event EIP712DomainChanged()
func (_OracleVerifier *OracleVerifierFilterer) WatchEIP712DomainChanged(opts *bind.WatchOpts, sink chan<- *OracleVerifierEIP712DomainChanged) (event.Subscription, error) {

	logs, sub, err := _OracleVerifier.contract.WatchLogs(opts, "EIP712DomainChanged")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(OracleVerifierEIP712DomainChanged)
				if err := _OracleVerifier.contract.UnpackLog(event, "EIP712DomainChanged", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseEIP712DomainChanged is a log parse operation binding the contract event 0x0a6387c9ea3628b88a633bb4f3b151770f70085117a15f9bf3787cda53f13d31.
//
// Solidity: event EIP712DomainChanged()
func (_OracleVerifier *OracleVerifierFilterer) ParseEIP712DomainChanged(log types.Log) (*OracleVerifierEIP712DomainChanged, error) {
	event := new(OracleVerifierEIP712DomainChanged)
	if err := _OracleVerifier.contract.UnpackLog(event, "EIP712DomainChanged", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// OracleVerifierReportLimitsUpdatedIterator is returned from FilterReportLimitsUpdated and is used to iterate over the raw logs and unpacked data for ReportLimitsUpdated events raised by the OracleVerifier contract.
type OracleVerifierReportLimitsUpdatedIterator struct {
	Event *OracleVerifierReportLimitsUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *OracleVerifierReportLimitsUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(OracleVerifierReportLimitsUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(OracleVerifierReportLimitsUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *OracleVerifierReportLimitsUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *OracleVerifierReportLimitsUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// OracleVerifierReportLimitsUpdated represents a ReportLimitsUpdated event raised by the OracleVerifier contract.
type OracleVerifierReportLimitsUpdated struct {
	MaxReportAge uint32
	MaxSpreadBps uint16
	Raw          types.Log // Blockchain specific contextual infos
}

// FilterReportLimitsUpdated is a free log retrieval operation binding the contract event 0xce44ae4eb3bc5a303e0bc68d713d264ec808b55560f90fc9d5b4888b347d26c8.
//
// Solidity: event ReportLimitsUpdated(uint32 maxReportAge, uint16 maxSpreadBps)
func (_OracleVerifier *OracleVerifierFilterer) FilterReportLimitsUpdated(opts *bind.FilterOpts) (*OracleVerifierReportLimitsUpdatedIterator, error) {

	logs, sub, err := _OracleVerifier.contract.FilterLogs(opts, "ReportLimitsUpdated")
	if err != nil {
		return nil, err
	}
	return &OracleVerifierReportLimitsUpdatedIterator{contract: _OracleVerifier.contract, event: "ReportLimitsUpdated", logs: logs, sub: sub}, nil
}

// WatchReportLimitsUpdated is a free log subscription operation binding the contract event 0xce44ae4eb3bc5a303e0bc68d713d264ec808b55560f90fc9d5b4888b347d26c8.
//
// Solidity: event ReportLimitsUpdated(uint32 maxReportAge, uint16 maxSpreadBps)
func (_OracleVerifier *OracleVerifierFilterer) WatchReportLimitsUpdated(opts *bind.WatchOpts, sink chan<- *OracleVerifierReportLimitsUpdated) (event.Subscription, error) {

	logs, sub, err := _OracleVerifier.contract.WatchLogs(opts, "ReportLimitsUpdated")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(OracleVerifierReportLimitsUpdated)
				if err := _OracleVerifier.contract.UnpackLog(event, "ReportLimitsUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseReportLimitsUpdated is a log parse operation binding the contract event 0xce44ae4eb3bc5a303e0bc68d713d264ec808b55560f90fc9d5b4888b347d26c8.
//
// Solidity: event ReportLimitsUpdated(uint32 maxReportAge, uint16 maxSpreadBps)
func (_OracleVerifier *OracleVerifierFilterer) ParseReportLimitsUpdated(log types.Log) (*OracleVerifierReportLimitsUpdated, error) {
	event := new(OracleVerifierReportLimitsUpdated)
	if err := _OracleVerifier.contract.UnpackLog(event, "ReportLimitsUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// OracleVerifierSignerSetUpdatedIterator is returned from FilterSignerSetUpdated and is used to iterate over the raw logs and unpacked data for SignerSetUpdated events raised by the OracleVerifier contract.
type OracleVerifierSignerSetUpdatedIterator struct {
	Event *OracleVerifierSignerSetUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *OracleVerifierSignerSetUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(OracleVerifierSignerSetUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(OracleVerifierSignerSetUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *OracleVerifierSignerSetUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *OracleVerifierSignerSetUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// OracleVerifierSignerSetUpdated represents a SignerSetUpdated event raised by the OracleVerifier contract.
type OracleVerifierSignerSetUpdated struct {
	Signers    []common.Address
	MinSigners uint8
	Raw        types.Log // Blockchain specific contextual infos
}

// FilterSignerSetUpdated is a free log retrieval operation binding the contract event 0x77ab1b4817128e6561abaf5f56ed3393a4032181938849f5ff1277e2583413a0.
//
// Solidity: event SignerSetUpdated(address[] signers, uint8 minSigners)
func (_OracleVerifier *OracleVerifierFilterer) FilterSignerSetUpdated(opts *bind.FilterOpts) (*OracleVerifierSignerSetUpdatedIterator, error) {

	logs, sub, err := _OracleVerifier.contract.FilterLogs(opts, "SignerSetUpdated")
	if err != nil {
		return nil, err
	}
	return &OracleVerifierSignerSetUpdatedIterator{contract: _OracleVerifier.contract, event: "SignerSetUpdated", logs: logs, sub: sub}, nil
}

// WatchSignerSetUpdated is a free log subscription operation binding the contract event 0x77ab1b4817128e6561abaf5f56ed3393a4032181938849f5ff1277e2583413a0.
//
// Solidity: event SignerSetUpdated(address[] signers, uint8 minSigners)
func (_OracleVerifier *OracleVerifierFilterer) WatchSignerSetUpdated(opts *bind.WatchOpts, sink chan<- *OracleVerifierSignerSetUpdated) (event.Subscription, error) {

	logs, sub, err := _OracleVerifier.contract.WatchLogs(opts, "SignerSetUpdated")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(OracleVerifierSignerSetUpdated)
				if err := _OracleVerifier.contract.UnpackLog(event, "SignerSetUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseSignerSetUpdated is a log parse operation binding the contract event 0x77ab1b4817128e6561abaf5f56ed3393a4032181938849f5ff1277e2583413a0.
//
// Solidity: event SignerSetUpdated(address[] signers, uint8 minSigners)
func (_OracleVerifier *OracleVerifierFilterer) ParseSignerSetUpdated(log types.Log) (*OracleVerifierSignerSetUpdated, error) {
	event := new(OracleVerifierSignerSetUpdated)
	if err := _OracleVerifier.contract.UnpackLog(event, "SignerSetUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// OrderBookMetaData contains all meta data concerning the OrderBook contract.
var OrderBookMetaData = &bind.MetaData{
	ABI: "[{\"inputs\":[{\"internalType\":\"contractIERC20\",\"name\":\"collateral_\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"authority_\",\"type\":\"address\"}],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"inputs\":[],\"name\":\"authority\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"orderId\",\"type\":\"uint256\"}],\"name\":\"cancelOrder\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"collateralToken\",\"outputs\":[{\"internalType\":\"contractIERC20\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"enumIOrderBook.OrderType\",\"name\":\"orderType\",\"type\":\"uint8\"},{\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"internalType\":\"uint256\",\"name\":\"sizeDeltaUsd\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"collateralDelta\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"triggerPrice\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"acceptablePrice\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"executionFee\",\"type\":\"uint256\"}],\"name\":\"createOrder\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"orderId\",\"type\":\"uint256\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"orderId\",\"type\":\"uint256\"},{\"components\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint64\",\"name\":\"timestamp\",\"type\":\"uint64\"},{\"internalType\":\"bytes\",\"name\":\"signature\",\"type\":\"bytes\"}],\"internalType\":\"structIOracleVerifier.SignedPriceReport[]\",\"name\":\"reports\",\"type\":\"tuple[]\"}],\"name\":\"executeOrder\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"orderId\",\"type\":\"uint256\"}],\"name\":\"getOrder\",\"outputs\":[{\"components\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"internalType\":\"enumIOrderBook.OrderType\",\"name\":\"orderType\",\"type\":\"uint8\"},{\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"internalType\":\"uint64\",\"name\":\"createdAt\",\"type\":\"uint64\"},{\"internalType\":\"uint128\",\"name\":\"sizeDeltaUsd\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"collateralDelta\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"triggerPrice\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"acceptablePrice\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"executionFee\",\"type\":\"uint128\"}],\"internalType\":\"structIOrderBook.Order\",\"name\":\"\",\"type\":\"tuple\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"isConsumingScheduledOp\",\"outputs\":[{\"internalType\":\"bytes4\",\"name\":\"\",\"type\":\"bytes4\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"orderId\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"}],\"name\":\"isExecutable\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"market\",\"outputs\":[{\"internalType\":\"contractIPerpsMarket\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"nextOrderId\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"newAuthority\",\"type\":\"address\"}],\"name\":\"setAuthority\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"totalEscrow\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"address\",\"name\":\"authority\",\"type\":\"address\"}],\"name\":\"AuthorityUpdated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"orderId\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"cancelledBy\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"bytes\",\"name\":\"reason\",\"type\":\"bytes\"}],\"name\":\"OrderCancelled\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"orderId\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"enumIOrderBook.OrderType\",\"name\":\"orderType\",\"type\":\"uint8\"},{\"indexed\":false,\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"sizeDeltaUsd\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"collateralDelta\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"triggerPrice\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"acceptablePrice\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"executionFee\",\"type\":\"uint256\"}],\"name\":\"OrderCreated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"uint256\",\"name\":\"orderId\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"keeper\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"oldestReportTimestamp\",\"type\":\"uint256\"}],\"name\":\"OrderExecuted\",\"type\":\"event\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"authority\",\"type\":\"address\"}],\"name\":\"AccessManagedInvalidAuthority\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"uint32\",\"name\":\"delay\",\"type\":\"uint32\"}],\"name\":\"AccessManagedRequiredDelay\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"}],\"name\":\"AccessManagedUnauthorized\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"cancellableAt\",\"type\":\"uint256\"}],\"name\":\"CancelTooEarly\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"EmptyOrder\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"fee\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"minFee\",\"type\":\"uint256\"}],\"name\":\"ExecutionFeeTooLow\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"ExecutionOutOfGas\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"triggerPrice\",\"type\":\"uint256\"}],\"name\":\"InvalidTriggerPrice\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"MarketPaused\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"address\",\"name\":\"owner\",\"type\":\"address\"}],\"name\":\"NotOrderOwner\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"ReentrancyGuardReentrantCall\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint8\",\"name\":\"bits\",\"type\":\"uint8\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"SafeCastOverflowedUintDowncast\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"token\",\"type\":\"address\"}],\"name\":\"SafeERC20FailedOperation\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"triggerPrice\",\"type\":\"uint256\"}],\"name\":\"TriggerNotMet\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"orderId\",\"type\":\"uint256\"}],\"name\":\"UnknownOrder\",\"type\":\"error\"}]",
}

// OrderBookABI is the input ABI used to generate the binding from.
// Deprecated: Use OrderBookMetaData.ABI instead.
var OrderBookABI = OrderBookMetaData.ABI

// OrderBook is an auto generated Go binding around an Ethereum contract.
type OrderBook struct {
	OrderBookCaller     // Read-only binding to the contract
	OrderBookTransactor // Write-only binding to the contract
	OrderBookFilterer   // Log filterer for contract events
}

// OrderBookCaller is an auto generated read-only Go binding around an Ethereum contract.
type OrderBookCaller struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// OrderBookTransactor is an auto generated write-only Go binding around an Ethereum contract.
type OrderBookTransactor struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// OrderBookFilterer is an auto generated log filtering Go binding around an Ethereum contract events.
type OrderBookFilterer struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// OrderBookSession is an auto generated Go binding around an Ethereum contract,
// with pre-set call and transact options.
type OrderBookSession struct {
	Contract     *OrderBook        // Generic contract binding to set the session for
	CallOpts     bind.CallOpts     // Call options to use throughout this session
	TransactOpts bind.TransactOpts // Transaction auth options to use throughout this session
}

// OrderBookCallerSession is an auto generated read-only Go binding around an Ethereum contract,
// with pre-set call options.
type OrderBookCallerSession struct {
	Contract *OrderBookCaller // Generic contract caller binding to set the session for
	CallOpts bind.CallOpts    // Call options to use throughout this session
}

// OrderBookTransactorSession is an auto generated write-only Go binding around an Ethereum contract,
// with pre-set transact options.
type OrderBookTransactorSession struct {
	Contract     *OrderBookTransactor // Generic contract transactor binding to set the session for
	TransactOpts bind.TransactOpts    // Transaction auth options to use throughout this session
}

// OrderBookRaw is an auto generated low-level Go binding around an Ethereum contract.
type OrderBookRaw struct {
	Contract *OrderBook // Generic contract binding to access the raw methods on
}

// OrderBookCallerRaw is an auto generated low-level read-only Go binding around an Ethereum contract.
type OrderBookCallerRaw struct {
	Contract *OrderBookCaller // Generic read-only contract binding to access the raw methods on
}

// OrderBookTransactorRaw is an auto generated low-level write-only Go binding around an Ethereum contract.
type OrderBookTransactorRaw struct {
	Contract *OrderBookTransactor // Generic write-only contract binding to access the raw methods on
}

// NewOrderBook creates a new instance of OrderBook, bound to a specific deployed contract.
func NewOrderBook(address common.Address, backend bind.ContractBackend) (*OrderBook, error) {
	contract, err := bindOrderBook(address, backend, backend, backend)
	if err != nil {
		return nil, err
	}
	return &OrderBook{OrderBookCaller: OrderBookCaller{contract: contract}, OrderBookTransactor: OrderBookTransactor{contract: contract}, OrderBookFilterer: OrderBookFilterer{contract: contract}}, nil
}

// NewOrderBookCaller creates a new read-only instance of OrderBook, bound to a specific deployed contract.
func NewOrderBookCaller(address common.Address, caller bind.ContractCaller) (*OrderBookCaller, error) {
	contract, err := bindOrderBook(address, caller, nil, nil)
	if err != nil {
		return nil, err
	}
	return &OrderBookCaller{contract: contract}, nil
}

// NewOrderBookTransactor creates a new write-only instance of OrderBook, bound to a specific deployed contract.
func NewOrderBookTransactor(address common.Address, transactor bind.ContractTransactor) (*OrderBookTransactor, error) {
	contract, err := bindOrderBook(address, nil, transactor, nil)
	if err != nil {
		return nil, err
	}
	return &OrderBookTransactor{contract: contract}, nil
}

// NewOrderBookFilterer creates a new log filterer instance of OrderBook, bound to a specific deployed contract.
func NewOrderBookFilterer(address common.Address, filterer bind.ContractFilterer) (*OrderBookFilterer, error) {
	contract, err := bindOrderBook(address, nil, nil, filterer)
	if err != nil {
		return nil, err
	}
	return &OrderBookFilterer{contract: contract}, nil
}

// bindOrderBook binds a generic wrapper to an already deployed contract.
func bindOrderBook(address common.Address, caller bind.ContractCaller, transactor bind.ContractTransactor, filterer bind.ContractFilterer) (*bind.BoundContract, error) {
	parsed, err := OrderBookMetaData.GetAbi()
	if err != nil {
		return nil, err
	}
	return bind.NewBoundContract(address, *parsed, caller, transactor, filterer), nil
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_OrderBook *OrderBookRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _OrderBook.Contract.OrderBookCaller.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_OrderBook *OrderBookRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _OrderBook.Contract.OrderBookTransactor.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_OrderBook *OrderBookRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _OrderBook.Contract.OrderBookTransactor.contract.Transact(opts, method, params...)
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_OrderBook *OrderBookCallerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _OrderBook.Contract.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_OrderBook *OrderBookTransactorRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _OrderBook.Contract.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_OrderBook *OrderBookTransactorRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _OrderBook.Contract.contract.Transact(opts, method, params...)
}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_OrderBook *OrderBookCaller) Authority(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _OrderBook.contract.Call(opts, &out, "authority")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_OrderBook *OrderBookSession) Authority() (common.Address, error) {
	return _OrderBook.Contract.Authority(&_OrderBook.CallOpts)
}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_OrderBook *OrderBookCallerSession) Authority() (common.Address, error) {
	return _OrderBook.Contract.Authority(&_OrderBook.CallOpts)
}

// CollateralToken is a free data retrieval call binding the contract method 0xb2016bd4.
//
// Solidity: function collateralToken() view returns(address)
func (_OrderBook *OrderBookCaller) CollateralToken(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _OrderBook.contract.Call(opts, &out, "collateralToken")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// CollateralToken is a free data retrieval call binding the contract method 0xb2016bd4.
//
// Solidity: function collateralToken() view returns(address)
func (_OrderBook *OrderBookSession) CollateralToken() (common.Address, error) {
	return _OrderBook.Contract.CollateralToken(&_OrderBook.CallOpts)
}

// CollateralToken is a free data retrieval call binding the contract method 0xb2016bd4.
//
// Solidity: function collateralToken() view returns(address)
func (_OrderBook *OrderBookCallerSession) CollateralToken() (common.Address, error) {
	return _OrderBook.Contract.CollateralToken(&_OrderBook.CallOpts)
}

// GetOrder is a free data retrieval call binding the contract method 0xd09ef241.
//
// Solidity: function getOrder(uint256 orderId) view returns((address,uint8,bool,uint64,uint128,uint128,uint128,uint128,uint128))
func (_OrderBook *OrderBookCaller) GetOrder(opts *bind.CallOpts, orderId *big.Int) (IOrderBookOrder, error) {
	var out []interface{}
	err := _OrderBook.contract.Call(opts, &out, "getOrder", orderId)

	if err != nil {
		return *new(IOrderBookOrder), err
	}

	out0 := *abi.ConvertType(out[0], new(IOrderBookOrder)).(*IOrderBookOrder)

	return out0, err

}

// GetOrder is a free data retrieval call binding the contract method 0xd09ef241.
//
// Solidity: function getOrder(uint256 orderId) view returns((address,uint8,bool,uint64,uint128,uint128,uint128,uint128,uint128))
func (_OrderBook *OrderBookSession) GetOrder(orderId *big.Int) (IOrderBookOrder, error) {
	return _OrderBook.Contract.GetOrder(&_OrderBook.CallOpts, orderId)
}

// GetOrder is a free data retrieval call binding the contract method 0xd09ef241.
//
// Solidity: function getOrder(uint256 orderId) view returns((address,uint8,bool,uint64,uint128,uint128,uint128,uint128,uint128))
func (_OrderBook *OrderBookCallerSession) GetOrder(orderId *big.Int) (IOrderBookOrder, error) {
	return _OrderBook.Contract.GetOrder(&_OrderBook.CallOpts, orderId)
}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_OrderBook *OrderBookCaller) IsConsumingScheduledOp(opts *bind.CallOpts) ([4]byte, error) {
	var out []interface{}
	err := _OrderBook.contract.Call(opts, &out, "isConsumingScheduledOp")

	if err != nil {
		return *new([4]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([4]byte)).(*[4]byte)

	return out0, err

}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_OrderBook *OrderBookSession) IsConsumingScheduledOp() ([4]byte, error) {
	return _OrderBook.Contract.IsConsumingScheduledOp(&_OrderBook.CallOpts)
}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_OrderBook *OrderBookCallerSession) IsConsumingScheduledOp() ([4]byte, error) {
	return _OrderBook.Contract.IsConsumingScheduledOp(&_OrderBook.CallOpts)
}

// IsExecutable is a free data retrieval call binding the contract method 0x3c50e5a4.
//
// Solidity: function isExecutable(uint256 orderId, uint256 price) view returns(bool)
func (_OrderBook *OrderBookCaller) IsExecutable(opts *bind.CallOpts, orderId *big.Int, price *big.Int) (bool, error) {
	var out []interface{}
	err := _OrderBook.contract.Call(opts, &out, "isExecutable", orderId, price)

	if err != nil {
		return *new(bool), err
	}

	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)

	return out0, err

}

// IsExecutable is a free data retrieval call binding the contract method 0x3c50e5a4.
//
// Solidity: function isExecutable(uint256 orderId, uint256 price) view returns(bool)
func (_OrderBook *OrderBookSession) IsExecutable(orderId *big.Int, price *big.Int) (bool, error) {
	return _OrderBook.Contract.IsExecutable(&_OrderBook.CallOpts, orderId, price)
}

// IsExecutable is a free data retrieval call binding the contract method 0x3c50e5a4.
//
// Solidity: function isExecutable(uint256 orderId, uint256 price) view returns(bool)
func (_OrderBook *OrderBookCallerSession) IsExecutable(orderId *big.Int, price *big.Int) (bool, error) {
	return _OrderBook.Contract.IsExecutable(&_OrderBook.CallOpts, orderId, price)
}

// Market is a free data retrieval call binding the contract method 0x80f55605.
//
// Solidity: function market() view returns(address)
func (_OrderBook *OrderBookCaller) Market(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _OrderBook.contract.Call(opts, &out, "market")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Market is a free data retrieval call binding the contract method 0x80f55605.
//
// Solidity: function market() view returns(address)
func (_OrderBook *OrderBookSession) Market() (common.Address, error) {
	return _OrderBook.Contract.Market(&_OrderBook.CallOpts)
}

// Market is a free data retrieval call binding the contract method 0x80f55605.
//
// Solidity: function market() view returns(address)
func (_OrderBook *OrderBookCallerSession) Market() (common.Address, error) {
	return _OrderBook.Contract.Market(&_OrderBook.CallOpts)
}

// NextOrderId is a free data retrieval call binding the contract method 0x2a58b330.
//
// Solidity: function nextOrderId() view returns(uint256)
func (_OrderBook *OrderBookCaller) NextOrderId(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _OrderBook.contract.Call(opts, &out, "nextOrderId")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// NextOrderId is a free data retrieval call binding the contract method 0x2a58b330.
//
// Solidity: function nextOrderId() view returns(uint256)
func (_OrderBook *OrderBookSession) NextOrderId() (*big.Int, error) {
	return _OrderBook.Contract.NextOrderId(&_OrderBook.CallOpts)
}

// NextOrderId is a free data retrieval call binding the contract method 0x2a58b330.
//
// Solidity: function nextOrderId() view returns(uint256)
func (_OrderBook *OrderBookCallerSession) NextOrderId() (*big.Int, error) {
	return _OrderBook.Contract.NextOrderId(&_OrderBook.CallOpts)
}

// TotalEscrow is a free data retrieval call binding the contract method 0xa3d89844.
//
// Solidity: function totalEscrow() view returns(uint256)
func (_OrderBook *OrderBookCaller) TotalEscrow(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _OrderBook.contract.Call(opts, &out, "totalEscrow")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// TotalEscrow is a free data retrieval call binding the contract method 0xa3d89844.
//
// Solidity: function totalEscrow() view returns(uint256)
func (_OrderBook *OrderBookSession) TotalEscrow() (*big.Int, error) {
	return _OrderBook.Contract.TotalEscrow(&_OrderBook.CallOpts)
}

// TotalEscrow is a free data retrieval call binding the contract method 0xa3d89844.
//
// Solidity: function totalEscrow() view returns(uint256)
func (_OrderBook *OrderBookCallerSession) TotalEscrow() (*big.Int, error) {
	return _OrderBook.Contract.TotalEscrow(&_OrderBook.CallOpts)
}

// CancelOrder is a paid mutator transaction binding the contract method 0x514fcac7.
//
// Solidity: function cancelOrder(uint256 orderId) returns()
func (_OrderBook *OrderBookTransactor) CancelOrder(opts *bind.TransactOpts, orderId *big.Int) (*types.Transaction, error) {
	return _OrderBook.contract.Transact(opts, "cancelOrder", orderId)
}

// CancelOrder is a paid mutator transaction binding the contract method 0x514fcac7.
//
// Solidity: function cancelOrder(uint256 orderId) returns()
func (_OrderBook *OrderBookSession) CancelOrder(orderId *big.Int) (*types.Transaction, error) {
	return _OrderBook.Contract.CancelOrder(&_OrderBook.TransactOpts, orderId)
}

// CancelOrder is a paid mutator transaction binding the contract method 0x514fcac7.
//
// Solidity: function cancelOrder(uint256 orderId) returns()
func (_OrderBook *OrderBookTransactorSession) CancelOrder(orderId *big.Int) (*types.Transaction, error) {
	return _OrderBook.Contract.CancelOrder(&_OrderBook.TransactOpts, orderId)
}

// CreateOrder is a paid mutator transaction binding the contract method 0xc239dd0e.
//
// Solidity: function createOrder(uint8 orderType, bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 triggerPrice, uint256 acceptablePrice, uint256 executionFee) returns(uint256 orderId)
func (_OrderBook *OrderBookTransactor) CreateOrder(opts *bind.TransactOpts, orderType uint8, isLong bool, sizeDeltaUsd *big.Int, collateralDelta *big.Int, triggerPrice *big.Int, acceptablePrice *big.Int, executionFee *big.Int) (*types.Transaction, error) {
	return _OrderBook.contract.Transact(opts, "createOrder", orderType, isLong, sizeDeltaUsd, collateralDelta, triggerPrice, acceptablePrice, executionFee)
}

// CreateOrder is a paid mutator transaction binding the contract method 0xc239dd0e.
//
// Solidity: function createOrder(uint8 orderType, bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 triggerPrice, uint256 acceptablePrice, uint256 executionFee) returns(uint256 orderId)
func (_OrderBook *OrderBookSession) CreateOrder(orderType uint8, isLong bool, sizeDeltaUsd *big.Int, collateralDelta *big.Int, triggerPrice *big.Int, acceptablePrice *big.Int, executionFee *big.Int) (*types.Transaction, error) {
	return _OrderBook.Contract.CreateOrder(&_OrderBook.TransactOpts, orderType, isLong, sizeDeltaUsd, collateralDelta, triggerPrice, acceptablePrice, executionFee)
}

// CreateOrder is a paid mutator transaction binding the contract method 0xc239dd0e.
//
// Solidity: function createOrder(uint8 orderType, bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 triggerPrice, uint256 acceptablePrice, uint256 executionFee) returns(uint256 orderId)
func (_OrderBook *OrderBookTransactorSession) CreateOrder(orderType uint8, isLong bool, sizeDeltaUsd *big.Int, collateralDelta *big.Int, triggerPrice *big.Int, acceptablePrice *big.Int, executionFee *big.Int) (*types.Transaction, error) {
	return _OrderBook.Contract.CreateOrder(&_OrderBook.TransactOpts, orderType, isLong, sizeDeltaUsd, collateralDelta, triggerPrice, acceptablePrice, executionFee)
}

// ExecuteOrder is a paid mutator transaction binding the contract method 0xf0029279.
//
// Solidity: function executeOrder(uint256 orderId, (address,uint256,uint64,bytes)[] reports) returns()
func (_OrderBook *OrderBookTransactor) ExecuteOrder(opts *bind.TransactOpts, orderId *big.Int, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _OrderBook.contract.Transact(opts, "executeOrder", orderId, reports)
}

// ExecuteOrder is a paid mutator transaction binding the contract method 0xf0029279.
//
// Solidity: function executeOrder(uint256 orderId, (address,uint256,uint64,bytes)[] reports) returns()
func (_OrderBook *OrderBookSession) ExecuteOrder(orderId *big.Int, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _OrderBook.Contract.ExecuteOrder(&_OrderBook.TransactOpts, orderId, reports)
}

// ExecuteOrder is a paid mutator transaction binding the contract method 0xf0029279.
//
// Solidity: function executeOrder(uint256 orderId, (address,uint256,uint64,bytes)[] reports) returns()
func (_OrderBook *OrderBookTransactorSession) ExecuteOrder(orderId *big.Int, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _OrderBook.Contract.ExecuteOrder(&_OrderBook.TransactOpts, orderId, reports)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_OrderBook *OrderBookTransactor) SetAuthority(opts *bind.TransactOpts, newAuthority common.Address) (*types.Transaction, error) {
	return _OrderBook.contract.Transact(opts, "setAuthority", newAuthority)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_OrderBook *OrderBookSession) SetAuthority(newAuthority common.Address) (*types.Transaction, error) {
	return _OrderBook.Contract.SetAuthority(&_OrderBook.TransactOpts, newAuthority)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_OrderBook *OrderBookTransactorSession) SetAuthority(newAuthority common.Address) (*types.Transaction, error) {
	return _OrderBook.Contract.SetAuthority(&_OrderBook.TransactOpts, newAuthority)
}

// OrderBookAuthorityUpdatedIterator is returned from FilterAuthorityUpdated and is used to iterate over the raw logs and unpacked data for AuthorityUpdated events raised by the OrderBook contract.
type OrderBookAuthorityUpdatedIterator struct {
	Event *OrderBookAuthorityUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *OrderBookAuthorityUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(OrderBookAuthorityUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(OrderBookAuthorityUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *OrderBookAuthorityUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *OrderBookAuthorityUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// OrderBookAuthorityUpdated represents a AuthorityUpdated event raised by the OrderBook contract.
type OrderBookAuthorityUpdated struct {
	Authority common.Address
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterAuthorityUpdated is a free log retrieval operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_OrderBook *OrderBookFilterer) FilterAuthorityUpdated(opts *bind.FilterOpts) (*OrderBookAuthorityUpdatedIterator, error) {

	logs, sub, err := _OrderBook.contract.FilterLogs(opts, "AuthorityUpdated")
	if err != nil {
		return nil, err
	}
	return &OrderBookAuthorityUpdatedIterator{contract: _OrderBook.contract, event: "AuthorityUpdated", logs: logs, sub: sub}, nil
}

// WatchAuthorityUpdated is a free log subscription operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_OrderBook *OrderBookFilterer) WatchAuthorityUpdated(opts *bind.WatchOpts, sink chan<- *OrderBookAuthorityUpdated) (event.Subscription, error) {

	logs, sub, err := _OrderBook.contract.WatchLogs(opts, "AuthorityUpdated")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(OrderBookAuthorityUpdated)
				if err := _OrderBook.contract.UnpackLog(event, "AuthorityUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseAuthorityUpdated is a log parse operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_OrderBook *OrderBookFilterer) ParseAuthorityUpdated(log types.Log) (*OrderBookAuthorityUpdated, error) {
	event := new(OrderBookAuthorityUpdated)
	if err := _OrderBook.contract.UnpackLog(event, "AuthorityUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// OrderBookOrderCancelledIterator is returned from FilterOrderCancelled and is used to iterate over the raw logs and unpacked data for OrderCancelled events raised by the OrderBook contract.
type OrderBookOrderCancelledIterator struct {
	Event *OrderBookOrderCancelled // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *OrderBookOrderCancelledIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(OrderBookOrderCancelled)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(OrderBookOrderCancelled)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *OrderBookOrderCancelledIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *OrderBookOrderCancelledIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// OrderBookOrderCancelled represents a OrderCancelled event raised by the OrderBook contract.
type OrderBookOrderCancelled struct {
	OrderId     *big.Int
	CancelledBy common.Address
	Reason      []byte
	Raw         types.Log // Blockchain specific contextual infos
}

// FilterOrderCancelled is a free log retrieval operation binding the contract event 0x9e7f7245fec8cd99826dd2023848acf23bb5eca944f437d40a2b9d7f3f30944c.
//
// Solidity: event OrderCancelled(uint256 indexed orderId, address indexed cancelledBy, bytes reason)
func (_OrderBook *OrderBookFilterer) FilterOrderCancelled(opts *bind.FilterOpts, orderId []*big.Int, cancelledBy []common.Address) (*OrderBookOrderCancelledIterator, error) {

	var orderIdRule []interface{}
	for _, orderIdItem := range orderId {
		orderIdRule = append(orderIdRule, orderIdItem)
	}
	var cancelledByRule []interface{}
	for _, cancelledByItem := range cancelledBy {
		cancelledByRule = append(cancelledByRule, cancelledByItem)
	}

	logs, sub, err := _OrderBook.contract.FilterLogs(opts, "OrderCancelled", orderIdRule, cancelledByRule)
	if err != nil {
		return nil, err
	}
	return &OrderBookOrderCancelledIterator{contract: _OrderBook.contract, event: "OrderCancelled", logs: logs, sub: sub}, nil
}

// WatchOrderCancelled is a free log subscription operation binding the contract event 0x9e7f7245fec8cd99826dd2023848acf23bb5eca944f437d40a2b9d7f3f30944c.
//
// Solidity: event OrderCancelled(uint256 indexed orderId, address indexed cancelledBy, bytes reason)
func (_OrderBook *OrderBookFilterer) WatchOrderCancelled(opts *bind.WatchOpts, sink chan<- *OrderBookOrderCancelled, orderId []*big.Int, cancelledBy []common.Address) (event.Subscription, error) {

	var orderIdRule []interface{}
	for _, orderIdItem := range orderId {
		orderIdRule = append(orderIdRule, orderIdItem)
	}
	var cancelledByRule []interface{}
	for _, cancelledByItem := range cancelledBy {
		cancelledByRule = append(cancelledByRule, cancelledByItem)
	}

	logs, sub, err := _OrderBook.contract.WatchLogs(opts, "OrderCancelled", orderIdRule, cancelledByRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(OrderBookOrderCancelled)
				if err := _OrderBook.contract.UnpackLog(event, "OrderCancelled", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseOrderCancelled is a log parse operation binding the contract event 0x9e7f7245fec8cd99826dd2023848acf23bb5eca944f437d40a2b9d7f3f30944c.
//
// Solidity: event OrderCancelled(uint256 indexed orderId, address indexed cancelledBy, bytes reason)
func (_OrderBook *OrderBookFilterer) ParseOrderCancelled(log types.Log) (*OrderBookOrderCancelled, error) {
	event := new(OrderBookOrderCancelled)
	if err := _OrderBook.contract.UnpackLog(event, "OrderCancelled", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// OrderBookOrderCreatedIterator is returned from FilterOrderCreated and is used to iterate over the raw logs and unpacked data for OrderCreated events raised by the OrderBook contract.
type OrderBookOrderCreatedIterator struct {
	Event *OrderBookOrderCreated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *OrderBookOrderCreatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(OrderBookOrderCreated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(OrderBookOrderCreated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *OrderBookOrderCreatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *OrderBookOrderCreatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// OrderBookOrderCreated represents a OrderCreated event raised by the OrderBook contract.
type OrderBookOrderCreated struct {
	OrderId         *big.Int
	Account         common.Address
	OrderType       uint8
	IsLong          bool
	SizeDeltaUsd    *big.Int
	CollateralDelta *big.Int
	TriggerPrice    *big.Int
	AcceptablePrice *big.Int
	ExecutionFee    *big.Int
	Raw             types.Log // Blockchain specific contextual infos
}

// FilterOrderCreated is a free log retrieval operation binding the contract event 0xd3a1164146eb83c011c8ac35f6d48b013553edaf9583eebd63593da17c9fcf14.
//
// Solidity: event OrderCreated(uint256 indexed orderId, address indexed account, uint8 orderType, bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 triggerPrice, uint256 acceptablePrice, uint256 executionFee)
func (_OrderBook *OrderBookFilterer) FilterOrderCreated(opts *bind.FilterOpts, orderId []*big.Int, account []common.Address) (*OrderBookOrderCreatedIterator, error) {

	var orderIdRule []interface{}
	for _, orderIdItem := range orderId {
		orderIdRule = append(orderIdRule, orderIdItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}

	logs, sub, err := _OrderBook.contract.FilterLogs(opts, "OrderCreated", orderIdRule, accountRule)
	if err != nil {
		return nil, err
	}
	return &OrderBookOrderCreatedIterator{contract: _OrderBook.contract, event: "OrderCreated", logs: logs, sub: sub}, nil
}

// WatchOrderCreated is a free log subscription operation binding the contract event 0xd3a1164146eb83c011c8ac35f6d48b013553edaf9583eebd63593da17c9fcf14.
//
// Solidity: event OrderCreated(uint256 indexed orderId, address indexed account, uint8 orderType, bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 triggerPrice, uint256 acceptablePrice, uint256 executionFee)
func (_OrderBook *OrderBookFilterer) WatchOrderCreated(opts *bind.WatchOpts, sink chan<- *OrderBookOrderCreated, orderId []*big.Int, account []common.Address) (event.Subscription, error) {

	var orderIdRule []interface{}
	for _, orderIdItem := range orderId {
		orderIdRule = append(orderIdRule, orderIdItem)
	}
	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}

	logs, sub, err := _OrderBook.contract.WatchLogs(opts, "OrderCreated", orderIdRule, accountRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(OrderBookOrderCreated)
				if err := _OrderBook.contract.UnpackLog(event, "OrderCreated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseOrderCreated is a log parse operation binding the contract event 0xd3a1164146eb83c011c8ac35f6d48b013553edaf9583eebd63593da17c9fcf14.
//
// Solidity: event OrderCreated(uint256 indexed orderId, address indexed account, uint8 orderType, bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 triggerPrice, uint256 acceptablePrice, uint256 executionFee)
func (_OrderBook *OrderBookFilterer) ParseOrderCreated(log types.Log) (*OrderBookOrderCreated, error) {
	event := new(OrderBookOrderCreated)
	if err := _OrderBook.contract.UnpackLog(event, "OrderCreated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// OrderBookOrderExecutedIterator is returned from FilterOrderExecuted and is used to iterate over the raw logs and unpacked data for OrderExecuted events raised by the OrderBook contract.
type OrderBookOrderExecutedIterator struct {
	Event *OrderBookOrderExecuted // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *OrderBookOrderExecutedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(OrderBookOrderExecuted)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(OrderBookOrderExecuted)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *OrderBookOrderExecutedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *OrderBookOrderExecutedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// OrderBookOrderExecuted represents a OrderExecuted event raised by the OrderBook contract.
type OrderBookOrderExecuted struct {
	OrderId               *big.Int
	Keeper                common.Address
	Price                 *big.Int
	OldestReportTimestamp *big.Int
	Raw                   types.Log // Blockchain specific contextual infos
}

// FilterOrderExecuted is a free log retrieval operation binding the contract event 0x79e7fef5cd17ce2c61fe594632f498fbf07d1bf082540b02861ad2a3afb745e0.
//
// Solidity: event OrderExecuted(uint256 indexed orderId, address indexed keeper, uint256 price, uint256 oldestReportTimestamp)
func (_OrderBook *OrderBookFilterer) FilterOrderExecuted(opts *bind.FilterOpts, orderId []*big.Int, keeper []common.Address) (*OrderBookOrderExecutedIterator, error) {

	var orderIdRule []interface{}
	for _, orderIdItem := range orderId {
		orderIdRule = append(orderIdRule, orderIdItem)
	}
	var keeperRule []interface{}
	for _, keeperItem := range keeper {
		keeperRule = append(keeperRule, keeperItem)
	}

	logs, sub, err := _OrderBook.contract.FilterLogs(opts, "OrderExecuted", orderIdRule, keeperRule)
	if err != nil {
		return nil, err
	}
	return &OrderBookOrderExecutedIterator{contract: _OrderBook.contract, event: "OrderExecuted", logs: logs, sub: sub}, nil
}

// WatchOrderExecuted is a free log subscription operation binding the contract event 0x79e7fef5cd17ce2c61fe594632f498fbf07d1bf082540b02861ad2a3afb745e0.
//
// Solidity: event OrderExecuted(uint256 indexed orderId, address indexed keeper, uint256 price, uint256 oldestReportTimestamp)
func (_OrderBook *OrderBookFilterer) WatchOrderExecuted(opts *bind.WatchOpts, sink chan<- *OrderBookOrderExecuted, orderId []*big.Int, keeper []common.Address) (event.Subscription, error) {

	var orderIdRule []interface{}
	for _, orderIdItem := range orderId {
		orderIdRule = append(orderIdRule, orderIdItem)
	}
	var keeperRule []interface{}
	for _, keeperItem := range keeper {
		keeperRule = append(keeperRule, keeperItem)
	}

	logs, sub, err := _OrderBook.contract.WatchLogs(opts, "OrderExecuted", orderIdRule, keeperRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(OrderBookOrderExecuted)
				if err := _OrderBook.contract.UnpackLog(event, "OrderExecuted", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseOrderExecuted is a log parse operation binding the contract event 0x79e7fef5cd17ce2c61fe594632f498fbf07d1bf082540b02861ad2a3afb745e0.
//
// Solidity: event OrderExecuted(uint256 indexed orderId, address indexed keeper, uint256 price, uint256 oldestReportTimestamp)
func (_OrderBook *OrderBookFilterer) ParseOrderExecuted(log types.Log) (*OrderBookOrderExecuted, error) {
	event := new(OrderBookOrderExecuted)
	if err := _OrderBook.contract.UnpackLog(event, "OrderExecuted", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketMetaData contains all meta data concerning the PerpsMarket contract.
var PerpsMarketMetaData = &bind.MetaData{
	ABI: "[{\"inputs\":[{\"internalType\":\"address\",\"name\":\"authority_\",\"type\":\"address\"},{\"internalType\":\"contractIERC20\",\"name\":\"collateral_\",\"type\":\"address\"},{\"internalType\":\"contractIOracleVerifier\",\"name\":\"oracle_\",\"type\":\"address\"},{\"internalType\":\"bytes32\",\"name\":\"marketId_\",\"type\":\"bytes32\"},{\"components\":[{\"internalType\":\"uint128\",\"name\":\"maxLongOpenInterest\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"maxShortOpenInterest\",\"type\":\"uint128\"},{\"internalType\":\"uint64\",\"name\":\"reserveFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxPnlFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"adlThresholdFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"adlTargetFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint16\",\"name\":\"positionFeeBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"initialMarginBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"maintenanceMarginBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"liquidationFeeBps\",\"type\":\"uint16\"},{\"internalType\":\"uint32\",\"name\":\"orderTimeout\",\"type\":\"uint32\"},{\"internalType\":\"uint128\",\"name\":\"minCollateral\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"positiveImpactFactor\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"negativeImpactFactor\",\"type\":\"uint128\"},{\"internalType\":\"uint64\",\"name\":\"borrowFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxFundingVelocity\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxFundingRate\",\"type\":\"uint64\"},{\"internalType\":\"uint128\",\"name\":\"skewScale\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"minExecutionFee\",\"type\":\"uint128\"}],\"internalType\":\"structIPerpsMarket.RiskParams\",\"name\":\"params_\",\"type\":\"tuple\"},{\"internalType\":\"string\",\"name\":\"vaultName\",\"type\":\"string\"},{\"internalType\":\"string\",\"name\":\"vaultSymbol\",\"type\":\"string\"}],\"stateMutability\":\"nonpayable\",\"type\":\"constructor\"},{\"inputs\":[],\"name\":\"IMPACT_POOL_DISTRIBUTION_PERIOD\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"}],\"name\":\"addLiquidity\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"authority\",\"outputs\":[{\"internalType\":\"address\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"components\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint64\",\"name\":\"timestamp\",\"type\":\"uint64\"},{\"internalType\":\"bytes\",\"name\":\"signature\",\"type\":\"bytes\"}],\"internalType\":\"structIOracleVerifier.SignedPriceReport[]\",\"name\":\"reports\",\"type\":\"tuple[]\"}],\"name\":\"autoDeleverage\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"collateralToken\",\"outputs\":[{\"internalType\":\"contractIERC20\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"components\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"internalType\":\"enumIOrderBook.OrderType\",\"name\":\"orderType\",\"type\":\"uint8\"},{\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"internalType\":\"uint64\",\"name\":\"createdAt\",\"type\":\"uint64\"},{\"internalType\":\"uint128\",\"name\":\"sizeDeltaUsd\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"collateralDelta\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"triggerPrice\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"acceptablePrice\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"executionFee\",\"type\":\"uint128\"}],\"internalType\":\"structIOrderBook.Order\",\"name\":\"order\",\"type\":\"tuple\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"}],\"name\":\"fillOrder\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"fundingIndex\",\"outputs\":[{\"internalType\":\"int256\",\"name\":\"\",\"type\":\"int256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"fundingRate\",\"outputs\":[{\"internalType\":\"int256\",\"name\":\"\",\"type\":\"int256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"}],\"name\":\"getPosition\",\"outputs\":[{\"components\":[{\"internalType\":\"uint128\",\"name\":\"sizeUsd\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"sizeInTokens\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"collateral\",\"type\":\"uint128\"},{\"internalType\":\"uint64\",\"name\":\"lastUpdatedAt\",\"type\":\"uint64\"},{\"internalType\":\"uint128\",\"name\":\"borrowIndexEntry\",\"type\":\"uint128\"},{\"internalType\":\"int128\",\"name\":\"fundingIndexEntry\",\"type\":\"int128\"}],\"internalType\":\"structIPerpsMarket.Position\",\"name\":\"\",\"type\":\"tuple\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"getRiskParams\",\"outputs\":[{\"components\":[{\"internalType\":\"uint128\",\"name\":\"maxLongOpenInterest\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"maxShortOpenInterest\",\"type\":\"uint128\"},{\"internalType\":\"uint64\",\"name\":\"reserveFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxPnlFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"adlThresholdFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"adlTargetFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint16\",\"name\":\"positionFeeBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"initialMarginBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"maintenanceMarginBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"liquidationFeeBps\",\"type\":\"uint16\"},{\"internalType\":\"uint32\",\"name\":\"orderTimeout\",\"type\":\"uint32\"},{\"internalType\":\"uint128\",\"name\":\"minCollateral\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"positiveImpactFactor\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"negativeImpactFactor\",\"type\":\"uint128\"},{\"internalType\":\"uint64\",\"name\":\"borrowFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxFundingVelocity\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxFundingRate\",\"type\":\"uint64\"},{\"internalType\":\"uint128\",\"name\":\"skewScale\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"minExecutionFee\",\"type\":\"uint128\"}],\"internalType\":\"structIPerpsMarket.RiskParams\",\"name\":\"\",\"type\":\"tuple\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"}],\"name\":\"getSide\",\"outputs\":[{\"components\":[{\"internalType\":\"uint256\",\"name\":\"openInterest\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"openInterestInTokens\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"borrowIndex\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"borrowEntrySum\",\"type\":\"uint256\"},{\"internalType\":\"int256\",\"name\":\"fundingEntrySum\",\"type\":\"int256\"}],\"internalType\":\"structIPerpsMarket.SideState\",\"name\":\"\",\"type\":\"tuple\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"getStats\",\"outputs\":[{\"components\":[{\"internalType\":\"uint128\",\"name\":\"positionFees\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"borrowFees\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"fundingPaidByTraders\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"fundingPaidToTraders\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"traderLosses\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"traderProfits\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"badDebt\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"keeperFees\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"impactCollected\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"impactPaid\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"lpDeposited\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"lpWithdrawn\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"liquidations\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"autoDeleverages\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"haircuts\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"impactDistributed\",\"type\":\"uint128\"}],\"internalType\":\"structIPerpsMarket.MarketStats\",\"name\":\"\",\"type\":\"tuple\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"impactPoolAmount\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"isConsumingScheduledOp\",\"outputs\":[{\"internalType\":\"bytes4\",\"name\":\"\",\"type\":\"bytes4\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"lastAccrualAt\",\"outputs\":[{\"internalType\":\"uint64\",\"name\":\"\",\"type\":\"uint64\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"lastPrice\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"lastPriceTimestamp\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"components\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint64\",\"name\":\"timestamp\",\"type\":\"uint64\"},{\"internalType\":\"bytes\",\"name\":\"signature\",\"type\":\"bytes\"}],\"internalType\":\"structIOracleVerifier.SignedPriceReport[]\",\"name\":\"reports\",\"type\":\"tuple[]\"}],\"name\":\"liquidate\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"marketId\",\"outputs\":[{\"internalType\":\"bytes32\",\"name\":\"\",\"type\":\"bytes32\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"oracle\",\"outputs\":[{\"internalType\":\"contractIOracleVerifier\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"orderBook\",\"outputs\":[{\"internalType\":\"contractOrderBook\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"paused\",\"outputs\":[{\"internalType\":\"bool\",\"name\":\"\",\"type\":\"bool\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"}],\"name\":\"pnlToPoolFactor\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"factor\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"positivePnl\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"poolAmount\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"poolValue\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"}],\"name\":\"poolValueAt\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"}],\"name\":\"positionInfo\",\"outputs\":[{\"components\":[{\"internalType\":\"int256\",\"name\":\"pnl\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"borrowFee\",\"type\":\"uint256\"},{\"internalType\":\"int256\",\"name\":\"fundingFee\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"closeFee\",\"type\":\"uint256\"},{\"internalType\":\"int256\",\"name\":\"remainingCollateral\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"maintenanceMargin\",\"type\":\"uint256\"},{\"internalType\":\"bool\",\"name\":\"liquidatable\",\"type\":\"bool\"}],\"internalType\":\"structIPerpsMarket.PositionInfo\",\"name\":\"info\",\"type\":\"tuple\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"components\":[{\"internalType\":\"address\",\"name\":\"signer\",\"type\":\"address\"},{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint64\",\"name\":\"timestamp\",\"type\":\"uint64\"},{\"internalType\":\"bytes\",\"name\":\"signature\",\"type\":\"bytes\"}],\"internalType\":\"structIOracleVerifier.SignedPriceReport[]\",\"name\":\"reports\",\"type\":\"tuple[]\"},{\"internalType\":\"uint256\",\"name\":\"notBefore\",\"type\":\"uint256\"}],\"name\":\"refreshPrice\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"oldestTimestamp\",\"type\":\"uint256\"}],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"},{\"internalType\":\"address\",\"name\":\"receiver\",\"type\":\"address\"}],\"name\":\"removeLiquidity\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"requestConfig\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"minExecutionFee\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"orderTimeout\",\"type\":\"uint256\"},{\"internalType\":\"bool\",\"name\":\"isPaused\",\"type\":\"bool\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"newAuthority\",\"type\":\"address\"}],\"name\":\"setAuthority\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"internalType\":\"bool\",\"name\":\"paused_\",\"type\":\"bool\"}],\"name\":\"setPaused\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[{\"components\":[{\"internalType\":\"uint128\",\"name\":\"maxLongOpenInterest\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"maxShortOpenInterest\",\"type\":\"uint128\"},{\"internalType\":\"uint64\",\"name\":\"reserveFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxPnlFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"adlThresholdFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"adlTargetFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint16\",\"name\":\"positionFeeBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"initialMarginBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"maintenanceMarginBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"liquidationFeeBps\",\"type\":\"uint16\"},{\"internalType\":\"uint32\",\"name\":\"orderTimeout\",\"type\":\"uint32\"},{\"internalType\":\"uint128\",\"name\":\"minCollateral\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"positiveImpactFactor\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"negativeImpactFactor\",\"type\":\"uint128\"},{\"internalType\":\"uint64\",\"name\":\"borrowFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxFundingVelocity\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxFundingRate\",\"type\":\"uint64\"},{\"internalType\":\"uint128\",\"name\":\"skewScale\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"minExecutionFee\",\"type\":\"uint128\"}],\"internalType\":\"structIPerpsMarket.RiskParams\",\"name\":\"newParams\",\"type\":\"tuple\"}],\"name\":\"setRiskParams\",\"outputs\":[],\"stateMutability\":\"nonpayable\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"totalCollateral\",\"outputs\":[{\"internalType\":\"uint256\",\"name\":\"\",\"type\":\"uint256\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"inputs\":[],\"name\":\"vault\",\"outputs\":[{\"internalType\":\"contractLPVault\",\"name\":\"\",\"type\":\"address\"}],\"stateMutability\":\"view\",\"type\":\"function\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"address\",\"name\":\"authority\",\"type\":\"address\"}],\"name\":\"AuthorityUpdated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"borrowFee\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"int256\",\"name\":\"fundingFee\",\"type\":\"int256\"}],\"name\":\"FeesSettled\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amount\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"poolAmount\",\"type\":\"uint256\"}],\"name\":\"ImpactPoolDistributed\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"int256\",\"name\":\"fundingRate\",\"type\":\"int256\"},{\"indexed\":false,\"internalType\":\"int256\",\"name\":\"fundingIndex\",\"type\":\"int256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"borrowIndexLong\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"borrowIndexShort\",\"type\":\"uint256\"}],\"name\":\"IndicesAccrued\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"poolAmount\",\"type\":\"uint256\"}],\"name\":\"LiquidityAdded\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"receiver\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"poolAmount\",\"type\":\"uint256\"}],\"name\":\"LiquidityRemoved\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"bool\",\"name\":\"paused\",\"type\":\"bool\"}],\"name\":\"PausedSet\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"sizeDeltaUsd\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"int256\",\"name\":\"realizedPnl\",\"type\":\"int256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amountOut\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"pnlFactorBefore\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"pnlFactorAfter\",\"type\":\"uint256\"}],\"name\":\"PositionAutoDeleveraged\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"sizeDeltaUsd\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"int256\",\"name\":\"realizedPnl\",\"type\":\"int256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"positionFee\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"int256\",\"name\":\"priceImpactUsd\",\"type\":\"int256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amountOut\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"badDebt\",\"type\":\"uint256\"}],\"name\":\"PositionDecreased\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"sizeDeltaUsd\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"collateralDelta\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"positionFee\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"int256\",\"name\":\"priceImpactUsd\",\"type\":\"int256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"sizeUsd\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"collateral\",\"type\":\"uint256\"}],\"name\":\"PositionIncreased\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":true,\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"indexed\":true,\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"},{\"indexed\":true,\"internalType\":\"address\",\"name\":\"keeper\",\"type\":\"address\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"sizeUsd\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"int256\",\"name\":\"remainingCollateral\",\"type\":\"int256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"keeperReward\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"amountOut\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"badDebt\",\"type\":\"uint256\"}],\"name\":\"PositionLiquidated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"indexed\":false,\"internalType\":\"uint256\",\"name\":\"timestamp\",\"type\":\"uint256\"}],\"name\":\"PriceUpdated\",\"type\":\"event\"},{\"anonymous\":false,\"inputs\":[{\"components\":[{\"internalType\":\"uint128\",\"name\":\"maxLongOpenInterest\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"maxShortOpenInterest\",\"type\":\"uint128\"},{\"internalType\":\"uint64\",\"name\":\"reserveFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxPnlFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"adlThresholdFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"adlTargetFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint16\",\"name\":\"positionFeeBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"initialMarginBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"maintenanceMarginBps\",\"type\":\"uint16\"},{\"internalType\":\"uint16\",\"name\":\"liquidationFeeBps\",\"type\":\"uint16\"},{\"internalType\":\"uint32\",\"name\":\"orderTimeout\",\"type\":\"uint32\"},{\"internalType\":\"uint128\",\"name\":\"minCollateral\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"positiveImpactFactor\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"negativeImpactFactor\",\"type\":\"uint128\"},{\"internalType\":\"uint64\",\"name\":\"borrowFactor\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxFundingVelocity\",\"type\":\"uint64\"},{\"internalType\":\"uint64\",\"name\":\"maxFundingRate\",\"type\":\"uint64\"},{\"internalType\":\"uint128\",\"name\":\"skewScale\",\"type\":\"uint128\"},{\"internalType\":\"uint128\",\"name\":\"minExecutionFee\",\"type\":\"uint128\"}],\"indexed\":false,\"internalType\":\"structIPerpsMarket.RiskParams\",\"name\":\"params\",\"type\":\"tuple\"}],\"name\":\"RiskParamsUpdated\",\"type\":\"event\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"price\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"acceptablePrice\",\"type\":\"uint256\"}],\"name\":\"AcceptablePriceExceeded\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"authority\",\"type\":\"address\"}],\"name\":\"AccessManagedInvalidAuthority\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"},{\"internalType\":\"uint32\",\"name\":\"delay\",\"type\":\"uint32\"}],\"name\":\"AccessManagedRequiredDelay\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"}],\"name\":\"AccessManagedUnauthorized\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"factorBefore\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"factorAfter\",\"type\":\"uint256\"}],\"name\":\"AdlDoesNotReduceFactor\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"pnlFactor\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"threshold\",\"type\":\"uint256\"}],\"name\":\"AdlNotRequired\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"int256\",\"name\":\"pnl\",\"type\":\"int256\"}],\"name\":\"AdlPositionNotProfitable\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"collateral\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"minCollateral\",\"type\":\"uint256\"}],\"name\":\"CollateralBelowMinimum\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"available\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"shortfall\",\"type\":\"uint256\"}],\"name\":\"InsufficientCollateral\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"bound\",\"type\":\"uint256\"}],\"name\":\"InvalidRiskParams\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"int256\",\"name\":\"effectiveCollateral\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"requiredMargin\",\"type\":\"uint256\"}],\"name\":\"MarginTooLow\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"account\",\"type\":\"address\"},{\"internalType\":\"bool\",\"name\":\"isLong\",\"type\":\"bool\"}],\"name\":\"NoPosition\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"int256\",\"name\":\"remainingCollateral\",\"type\":\"int256\"},{\"internalType\":\"uint256\",\"name\":\"maintenanceMargin\",\"type\":\"uint256\"}],\"name\":\"NotLiquidatable\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"openInterest\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"cap\",\"type\":\"uint256\"}],\"name\":\"OpenInterestCapExceeded\",\"type\":\"error\"},{\"inputs\":[],\"name\":\"ReentrancyGuardReentrantCall\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint8\",\"name\":\"bits\",\"type\":\"uint8\"},{\"internalType\":\"int256\",\"name\":\"value\",\"type\":\"int256\"}],\"name\":\"SafeCastOverflowedIntDowncast\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint8\",\"name\":\"bits\",\"type\":\"uint8\"},{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"SafeCastOverflowedUintDowncast\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"value\",\"type\":\"uint256\"}],\"name\":\"SafeCastOverflowedUintToInt\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"token\",\"type\":\"address\"}],\"name\":\"SafeERC20FailedOperation\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"address\",\"name\":\"caller\",\"type\":\"address\"}],\"name\":\"UnauthorizedCaller\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint8\",\"name\":\"decimals\",\"type\":\"uint8\"}],\"name\":\"UnsupportedCollateralDecimals\",\"type\":\"error\"},{\"inputs\":[{\"internalType\":\"uint256\",\"name\":\"assets\",\"type\":\"uint256\"},{\"internalType\":\"uint256\",\"name\":\"poolAmount\",\"type\":\"uint256\"}],\"name\":\"WithdrawalExceedsFreeLiquidity\",\"type\":\"error\"}]",
	Bin: "0x610120604052348015610010575f5ffd5b5060405161b3a038038061b3a083398101604081905261002f9161095b565b86610039816101ac565b505f866001600160a01b031663313ce5676040518163ffffffff1660e01b8152600401602060405180830381865afa158015610077573d5f5f3e3d5ffd5b505050506040513d601f19601f8201168201806040525081019061009b9190610b7f565b905080601260ff8216146100cd57604051631796bed360e31b815260ff90911660048201526024015b60405180910390fd5b506001600160a01b0380881660a052861660c052608085905260405187908990859085906100fa9061080f565b6101079493929190610bd4565b604051809103905ff080158015610120573d5f5f3e3d5ffd5b506001600160a01b031660e0526040518790899061013d9061081c565b6001600160a01b03928316815291166020820152604001604051809103905ff08015801561016d573d5f5f3e3d5ffd5b506001600160a01b031661010052601680546001600160401b031916426001600160401b031617905561019f846101ff565b5050505050505050610e3f565b5f80546001600160a01b0319166001600160a01b0383169081179091556040519081527f2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad9060200160405180910390a150565b60408101516001600160401b0316158015906102305750670de0b6b3a764000081604001516001600160401b031611155b6001906102535760405163581bbb4760e11b81526004016100c491815260200190565b5060a08101516001600160401b031615801590610289575080608001516001600160401b03168160a001516001600160401b0316105b80156102ae575080606001516001600160401b031681608001516001600160401b0316105b80156102ce5750670de0b6b3a764000081606001516001600160401b0316105b6002906102f15760405163581bbb4760e11b81526004016100c491815260200190565b5060648160c0015161ffff1611156003906103225760405163581bbb4760e11b81526004016100c491815260200190565b5061010081015161ffff161580159061034b57508060e0015161ffff1681610100015161ffff16105b801561036157506127108160e0015161ffff1611155b6004906103845760405163581bbb4760e11b81526004016100c491815260200190565b5080610100015161ffff1681610120015161ffff16106005906103bd5760405163581bbb4760e11b81526004016100c491815260200190565b50806101a001516001600160801b03168161018001516001600160801b031611156006906104015760405163581bbb4760e11b81526004016100c491815260200190565b506102208101516007906001600160801b03166104345760405163581bbb4760e11b81526004016100c491815260200190565b50600a81610140015163ffffffff161015801561045f57506201518081610140015163ffffffff1611155b6008906104825760405163581bbb4760e11b81526004016100c491815260200190565b506424ea4122ae816101c001516001600160401b031611156009906104bd5760405163581bbb4760e11b81526004016100c491815260200190565b50650286c0752c718161020001516001600160401b0316111580156104f457506302653766816101e001516001600160401b031611155b600a906105175760405163581bbb4760e11b81526004016100c491815260200190565b5064012a05f200816101a001516001600160801b03161115600b906105525760405163581bbb4760e11b81526004016100c491815260200190565b50678ac7230489e800008161024001516001600160801b0316111580156105905750683635c9adc5dea000008161016001516001600160801b031611155b600c906105b35760405163581bbb4760e11b81526004016100c491815260200190565b50805160208201516001600160801b03918216600160801b9183168202176001556040830151600280546060860151608087015160a08801516001600160401b039586166001600160801b03199485161768010000000000000000938716840217881691861687026001600160c01b031691909117600160c01b918616919091021790925560c08601516003805460e08901516101008a01516101208b01516101408c01516101608d015161ffff97881663ffffffff199096169590951762010000948816949094029390931763ffffffff60201b19166401000000009287169290920261ffff60301b1916919091176601000000000000959091169490940293909317600160401b600160e01b03191663ffffffff9093168502600160601b600160e01b031916929092176c01000000000000000000000000928816929092029190911790556101808601516101a08701519086169086168502176004556101c0860151600580546101e08901516102008a0151600160801b600160c01b03199488169290951691909117908616909402939093171692168084029290921790556102208401516102408501519084169316909102919091176006555f9061077b906107df565b90506107a06014548261078d90610c1c565b8082129082180218828113818418021890565b6014556040517fc7f36dc8e3119a25b581eae687b05812e2a091f775868e748400edb677136f95906107d3908490610c42565b60405180910390a15050565b5f6001600160ff1b0382111561080b5760405163123baf0360e11b8152600481018390526024016100c4565b5090565b612aa580616bf083390190565b611d0b8061969583390190565b6001600160a01b038116811461083d575f5ffd5b50565b634e487b7160e01b5f52604160045260245ffd5b60405161026081016001600160401b038111828210171561087757610877610840565b60405290565b80516001600160801b0381168114610893575f5ffd5b919050565b80516001600160401b0381168114610893575f5ffd5b805161ffff81168114610893575f5ffd5b805163ffffffff81168114610893575f5ffd5b5f82601f8301126108e1575f5ffd5b81516001600160401b038111156108fa576108fa610840565b604051601f8201601f19908116603f011681016001600160401b038111828210171561092857610928610840565b60405281815283820160200185101561093f575f5ffd5b8160208501602083015e5f918101602001919091529392505050565b5f5f5f5f5f5f5f610320888a031215610972575f5ffd5b875161097d81610829565b602089015190975061098e81610829565b604089015190965061099f81610829565b8095505060608801519350608088015f610260828c0312156109bf575f5ffd5b6109c7610854565b90506109d28261087d565b81526109e06020830161087d565b60208201526109f160408301610898565b6040820152610a0260608301610898565b6060820152610a1360808301610898565b6080820152610a2460a08301610898565b60a0820152610a3560c083016108ae565b60c0820152610a4660e083016108ae565b60e0820152610a5861010083016108ae565b610100820152610a6b61012083016108ae565b610120820152610a7e61014083016108bf565b610140820152610a91610160830161087d565b610160820152610aa4610180830161087d565b610180820152610ab76101a0830161087d565b6101a0820152610aca6101c08301610898565b6101c0820152610add6101e08301610898565b6101e0820152610af06102008301610898565b610200820152610b03610220830161087d565b610220820152610b16610240830161087d565b6102408201526102e08a015190945090506001600160401b03811115610b3a575f5ffd5b610b468a828b016108d2565b6103008a015190935090506001600160401b03811115610b64575f5ffd5b610b708a828b016108d2565b91505092959891949750929550565b5f60208284031215610b8f575f5ffd5b815160ff81168114610b9f575f5ffd5b9392505050565b5f81518084528060208401602086015e5f602082860101526020601f19601f83011685010191505092915050565b6001600160a01b038581168252841660208201526080604082018190525f90610bff90830185610ba6565b8281036060840152610c118185610ba6565b979650505050505050565b5f600160ff1b8201610c3c57634e487b7160e01b5f52601160045260245ffd5b505f0390565b81516001600160801b0316815261026081016020830151610c6e60208401826001600160801b03169052565b506040830151610c8960408401826001600160401b03169052565b506060830151610ca460608401826001600160401b03169052565b506080830151610cbf60808401826001600160401b03169052565b5060a0830151610cda60a08401826001600160401b03169052565b5060c0830151610cf060c084018261ffff169052565b5060e0830151610d0660e084018261ffff169052565b50610100830151610d1e61010084018261ffff169052565b50610120830151610d3661012084018261ffff169052565b50610140830151610d5061014084018263ffffffff169052565b50610160830151610d6d6101608401826001600160801b03169052565b50610180830151610d8a6101808401826001600160801b03169052565b506101a0830151610da76101a08401826001600160801b03169052565b506101c0830151610dc46101c08401826001600160401b03169052565b506101e0830151610de16101e08401826001600160401b03169052565b50610200830151610dfe6102008401826001600160401b03169052565b50610220830151610e1b6102208401826001600160801b03169052565b50610240830151610e386102408401826001600160801b03169052565b5092915050565b60805160a05160c05160e05161010051615d12610ede5f395f818161056201528181610b420152610e1701525f81816109430152818161097801528181610e490152610ec901525f81816105b4015261266701525f818161066b01528181610a9301528181610cba01528181610dce01528181610fc4015281816112ea0152818161188d015261389401525f818161053b01526126960152615d125ff3fe608060405234801561000f575f5ffd5b5060043610610208575f3560e01c80637a9e5e4b1161011f578063ba8c1d5b116100a9578063caf17f0111610079578063caf17f01146108fc578063d6bb48041461090f578063ef165dd914610922578063f2df39cb1461092b578063fbfa77cf1461093e575f5ffd5b8063ba8c1d5b14610695578063bf7e214f146106ff578063c59d48471461070f578063c968b70e1461086e575f5ffd5b80638fb36037116100ef5780638fb360371461063357806399be963214610654578063a693600b1461065d578063b2016bd414610666578063b86150711461068d575f5ffd5b80637a9e5e4b1461059c5780637dc0d1d0146105af5780637de93f93146105d657806380f85260146105df575f5ffd5b806351c6590a116101a05780635c975abb116101705780635c975abb1461034e5780635e1d515c14610372578063697947951461037c5780636ed71ede14610536578063776af5ba1461055d575f5ffd5b806351c6590a146102c857806352566e93146102db57806358e89fbc146103285780635ab168e81461033b575f5ffd5b80633131fd71116101db5780633131fd711461026357806341d3c84c1461028e5780634ac8eb5f146102975780634bb28349146102a0575f5ffd5b8063053f14da1461020c57806305fe138b1461022857806316c38b3c1461023d578063236490f414610250575b5f5ffd5b61021560175481565b6040519081526020015b60405180910390f35b61023b61023636600461519c565b610965565b005b61023b61024b3660046151d5565b610ac6565b61023b61025e3660046151ee565b610b2f565b601654610276906001600160401b031681565b6040516001600160401b03909116815260200161021f565b61021560145481565b61021560095481565b6102b36102ae366004615266565b610e02565b6040805192835260208301919091520161021f565b61023b6102d63660046152ad565b610eb6565b600654600354601654600160801b9092046001600160801b031691600160401b9182900463ffffffff1691900460ff1660408051938452602084019290925215159082015260600161021f565b61023b6103363660046152c4565b610ff7565b61023b6103493660046152de565b61101f565b60165461036290600160401b900460ff1681565b604051901515815260200161021f565b61021562093a8081565b61052960408051610260810182525f80825260208201819052918101829052606081018290526080810182905260a0810182905260c0810182905260e08101829052610100810182905261012081018290526101408101829052610160810182905261018081018290526101a081018290526101c081018290526101e08101829052610200810182905261022081018290526102408101919091525060408051610260810182526001546001600160801b038082168352600160801b91829004811660208401526002546001600160401b0380821695850195909552600160401b8082048616606086015283820486166080860152600160c01b909104851660a085015260035461ffff80821660c0870152620100008204811660e0870152600160201b82048116610100870152600160301b82041661012086015263ffffffff82820416610140860152600160601b9004821661016085015260045480831661018086015283900482166101a08501526005548086166101c086015290810485166101e08501528290049093166102008301526006548084166102208401520490911661024082015290565b60405161021f919061533a565b6102157f000000000000000000000000000000000000000000000000000000000000000081565b6105847f000000000000000000000000000000000000000000000000000000000000000081565b6040516001600160a01b03909116815260200161021f565b61023b6105aa366004615537565b611329565b6105847f000000000000000000000000000000000000000000000000000000000000000081565b61021560185481565b6105f26105ed3660046151d5565b61139d565b60405161021f91905f60a082019050825182526020830151602083015260408301516040830152606083015160608301526080830151608083015292915050565b61063b611412565b6040516001600160e01b0319909116815260200161021f565b61021560155481565b61021560075481565b6105847f000000000000000000000000000000000000000000000000000000000000000081565b610215611436565b6106a86106a3366004615550565b611442565b60405161021f91905f60e082019050825182526020830151602083015260408301516040830152606083015160608301526080830151608083015260a083015160a083015260c0830151151560c083015292915050565b5f546001600160a01b0316610584565b61086160408051610200810182525f80825260208201819052918101829052606081018290526080810182905260a0810182905260c0810182905260e08101829052610100810182905261012081018290526101408101829052610160810182905261018081018290526101a081018290526101c081018290526101e0810191909152506040805161020081018252601a546001600160801b038082168352600160801b918290048116602080850191909152601b54808316958501959095529382900481166060840152601c548082166080850152829004811660a0840152601d5480821660c0850152829004811660e0840152601e548082166101008501528290048116610120840152601f548082166101408501528290048116610160840152925480841661018084015281900483166101a08301526021548084166101c0840152049091166101e082015290565b60405161021f919061558a565b61088161087c366004615740565b611563565b60405161021f91905f60c0820190506001600160801b0383511682526001600160801b0360208401511660208301526001600160801b0360408401511660408301526001600160401b0360608401511660608301526001600160801b03608084015116608083015260a0830151600f0b60a083015292915050565b61021561090a3660046152ad565b611624565b61023b61091d3660046152de565b61162e565b61021560085481565b6102b36109393660046152ad565b6118c1565b6105847f000000000000000000000000000000000000000000000000000000000000000081565b61096d6118d5565b336001600160a01b037f00000000000000000000000000000000000000000000000000000000000000001681146109c85760405163d86ad9cf60e01b81526001600160a01b0390911660048201526024015b60405180910390fd5b506109d28261190c565b8160075f8282546109e3919061577c565b909155506109f2905082611b16565b601f8054601090610a14908490600160801b90046001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b03160217905550806001600160a01b03167f7cd78db3fa0f169740484c879803073b63a35c4c5d82f02312e7aa988eee855483600754604051610a7e929190918252602082015260400190565b60405180910390a2610aba6001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000168284611b4d565b610ac2611b87565b5050565b610ad2335b5f36611bb1565b60168054821515600160401b0268ff0000000000000000199091161790556040517f40db37ff5c0bdc2c427fbb2078c8f24afea940abac0e3c23bb4ea3bf2da2b21290610b2490831515815260200190565b60405180910390a150565b610b376118d5565b336001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000168114610b8d5760405163d86ad9cf60e01b81526001600160a01b0390911660048201526024016109bf565b505f610b9f60408401602085016157ae565b90505f80826004811115610bb557610bb56157cc565b1480610bd257506002826004811115610bd057610bd06157cc565b145b90505f811515610be860608701604088016151d5565b151514905080610c1457610c03610100860160e087016157f6565b6001600160801b0316841015610c32565b610c25610100860160e087016157f6565b6001600160801b03168411155b84610c44610100880160e089016157f6565b9091610c7557604051633166601f60e01b815260048101929092526001600160801b031660248201526044016109bf565b50508115610d4857610c8d60c0860160a087016157f6565b6001600160801b031615610ceb57610ceb3330610cb060c0890160a08a016157f6565b6001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000169291906001600160801b0316611ca7565b610d43610cfb6020870187615537565b610d0b60608801604089016151d5565b610d1b60a0890160808a016157f6565b6001600160801b0316610d3460c08a0160a08b016157f6565b6001600160801b031688611cdd565b610df7565b5f610da2610d596020880188615537565b610d696060890160408a016151d5565b610d7960a08a0160808b016157f6565b6001600160801b0316610d9260c08b0160a08c016157f6565b6001600160801b0316895f612304565b905080608001515f14610df557610df5610dbf6020880188615537565b60808301516001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000169190611b4d565b505b505050610ac2611b87565b5f5f610e0c6118d5565b336001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000161480610e6b5750336001600160a01b037f000000000000000000000000000000000000000000000000000000000000000016145b3390610e965760405163d86ad9cf60e01b81526001600160a01b0390911660048201526024016109bf565b50610ea2858585612663565b91509150610eae611b87565b935093915050565b610ebe6118d5565b336001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000168114610f145760405163d86ad9cf60e01b81526001600160a01b0390911660048201526024016109bf565b508060075f828254610f26919061580f565b90915550610f35905081611b16565b601f80545f90610f4f9084906001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055507f38f8a0c92f4c5b0b6877f878cb4c0c8d348a47b76d716c8e78f425043df9515b81600754604051610faf929190918252602082015260400190565b60405180910390a1610fec6001600160a01b037f000000000000000000000000000000000000000000000000000000000000000016333084611ca7565b610ff4611b87565b50565b61100033610acb565b61100861276d565b610ff461101a36839003830183615891565b6128fd565b6110276118d5565b61103033610acb565b6001600160a01b0384165f9081526019602090815260408083208615158452825291829020825160c08101845281546001600160801b03808216808452600160801b92839004821695840195909552600184015480821696840196909652948190046001600160401b0316606083015260029092015493841660808201529204600f0b60a0830152859085906110ec576040516345e40db960e11b81526001600160a01b039092166004830152151560248201526044016109bf565b50505f611107848484606001516001600160401b0316612663565b5090505f5f61111583612ee7565b6002549193509150600160801b90046001600160401b0316828180821161115857604051630b8a952560e21b8152600481019290925260248201526044016109bf565b50505f61118089875f01516001600160801b031688602001516001600160801b031688612f63565b9050805f81136111a657604051639efac3a560e01b81526004016109bf91815260200190565b505f6111bf875f01516001600160801b03168386612fd3565b90505f6111d18c8c845f8b6002612304565b90505f6111dd88612ee7565b509050868181811061120b5760405163220a8bbb60e11b8152600481019290925260248201526044016109bf565b50506020805460109061122d90600160801b90046001600160801b0316615a06565b91906101000a8154816001600160801b0302191690836001600160801b031602179055508b15158d6001600160a01b03167f6a550c0cf4f1e78a715b619071c4b654c2f94e497b712c334b33f64f6a81948a845f01518b866020015187608001518d886040516112c596959493929190958652602086019490945260408501929092526060840152608083015260a082015260c00190565b60405180910390a3608082015115611312576080820151611312906001600160a01b037f000000000000000000000000000000000000000000000000000000000000000016908f90611b4d565b505050505050505050611323611b87565b50505050565b5f5433906001600160a01b0316811461135f5760405162d1953b60e31b81526001600160a01b03821660048201526024016109bf565b816001600160a01b03163b5f03611394576040516361798f2f60e11b81526001600160a01b03831660048201526024016109bf565b610ac2826130ef565b6113ca6040518060a001604052805f81526020015f81526020015f81526020015f81526020015f81525090565b6113d38261313c565b6040805160a081018252825481526001830154602082015260028301549181019190915260038201546060820152600490910154608082015292915050565b5f8054600160a01b900460ff1661142857505f90565b638fb3603760e01b5b905090565b5f611431601754613151565b61147d6040518060e001604052805f81526020015f81526020015f81526020015f81526020015f81526020015f81526020015f151581525090565b6001600160a01b0384165f90815260196020908152604080832086151584528252808320815160c08101835281546001600160801b03808216808452600160801b92839004821696840196909652600184015480821695840195909552938190046001600160401b0316606083015260029092015492831660808201529104600f0b60a08201529103611510575061155c565b6016545f908190819061153590611530906001600160401b03164261577c565b6133d0565b935093509350506115558488888a61154d578461154f565b855b876135c5565b9450505050505b9392505050565b6040805160c0810182525f80825260208201819052918101829052606081018290526080810182905260a0810191909152506001600160a01b0382165f9081526019602090815260408083208415158452825291829020825160c08101845281546001600160801b038082168352600160801b91829004811694830194909452600183015480851695830195909552938490046001600160401b031660608201526002909101549182166080820152919004600f0b60a08201525b92915050565b5f61161e82613151565b6116366118d5565b61163f33610acb565b6001600160a01b0384165f9081526019602090815260408083208615158452825291829020825160c08101845281546001600160801b03808216808452600160801b92839004821695840195909552600184015480821696840196909652948190046001600160401b0316606083015260029092015493841660808201529204600f0b60a0830152859085906116fb576040516345e40db960e11b81526001600160a01b039092166004830152151560248201526044016109bf565b50505f611716848484606001516001600160401b0316612663565b5090505f6117358387846117298a61313c565b600201546015546135c5565b90508060c0015181608001518260a00151909161176e57604051631e82970160e21b8152600481019290925260248201526044016109bf565b50505f61178c8888865f01516001600160801b03165f876001612304565b60208054919250905f906117a8906001600160801b0316615a06565b91906101000a8154816001600160801b0302191690836001600160801b03160217905550336001600160a01b0316871515896001600160a01b03167fc169e66b719a87fd1cb816cf4c8bb389307ca8f0fdfd4a73ee1022611196c7de86885f015187608001518760c0015188608001518960a0015160405161185b969594939291909586526001600160801b0394909416602086015260408501929092526060840152608083015260a082015260c00190565b60405180910390a46118708160c00151613834565b6080810151156118b55760808101516118b5906001600160a01b037f000000000000000000000000000000000000000000000000000000000000000016908a90611b4d565b50505050611323611b87565b5f5f6118cc83612ee7565b91509150915091565b6118dd6138cb565b61190a60017f9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f005b9061390b565b565b60075481818082111561193a57604051628c948960e01b8152600481019290925260248201526044016109bf565b505f9050611948838361577c565b60408051610260810182526001546001600160801b038082168352600160801b91829004811660208401526002546001600160401b03808216958501869052600160401b8083048216606087015284830482166080870152600160c01b909204811660a086015260035461ffff80821660c0880152620100008204811660e0880152600160201b82048116610100880152600160301b82041661012087015263ffffffff83820416610140870152600160601b9004831661016086015260045480841661018087015284900483166101a08601526005548082166101c087015291820481166101e0860152908390041661020084015260065480821661022085015291909104166102408201529192505f90611a6e908490670de0b6b3a7640000613912565b905080600a5f015411158015611a865750600f548110155b85859091611aaf57604051628c948960e01b8152600481019290925260248201526044016109bf565b50505f611abd601754612ee7565b915050611ae08484608001516001600160401b0316670de0b6b3a7640000613912565b81111586869091611b0c57604051628c948960e01b8152600481019290925260248201526044016109bf565b5050505050505050565b5f6001600160801b03821115611b49576040516306dfcc6560e41b815260806004820152602481018390526044016109bf565b5090565b611b5a83838360016139a0565b611b8257604051635274afe760e01b81526001600160a01b03841660048201526024016109bf565b505050565b61190a5f7f9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00611904565b5f5f611be4611bc75f546001600160a01b031690565b8630611bd660045f898b615a30565b611bdf91615a57565b613a02565b9150915081611ca05763ffffffff811615611c7d575f805460ff60a01b198116600160a01b17909155604051634a63ebf760e11b81526001600160a01b03909116906394c7d7ee90611c3e90889088908890600401615ab5565b5f604051808303815f87803b158015611c55575f5ffd5b505af1158015611c67573d5f5f3e3d5ffd5b50505f805460ff60a01b1916905550611ca09050565b60405162d1953b60e31b81526001600160a01b03861660048201526024016109bf565b5050505050565b611cb5848484846001613a94565b61132357604051635274afe760e01b81526001600160a01b03851660048201526024016109bf565b60408051610260810182526001546001600160801b038082168352600160801b91829004811660208401526002546001600160401b0380821695850195909552600160401b8082048616606086015283820486166080860152600160c01b909104851660a085015260035461ffff80821660c0870152620100008204811660e0870152600160201b82048116610100870152600160301b82041661012086015263ffffffff82820416610140860152600160601b9004821661016085015260045480831661018086015283900482166101a08501526005548086166101c086015290810485166101e0850152829004909316610200830152600654808416610220840152049091166102408201525f611df58661313c565b6001600160a01b0388165f9081526019602090815260408083208a15158452825291829020825160c08101845281546001600160801b03808216808452600160801b92839004821695840195909552600184015480821696840196909652948190046001600160401b0316606083015260029092015493841660808201529204600f0b60a083015291925090151580611e8d57508515155b88889091611ec1576040516345e40db960e11b81526001600160a01b039092166004830152151560248201526044016109bf565b5050611ef66040518060c001604052805f81526020015f81526020015f81526020015f81526020015f81526020015f81525090565b611f0882898560020154601554613b01565b6040830152602082015260c0840151611f2690889061ffff16613ba2565b6060820152611f388860018987613bb0565b608082015260408201515f90611f6290611f5c9089906001600160801b031661580f565b83613c1c565b905080602001515f148784604001516001600160801b0316611f84919061580f565b82602001519091611fb157604051632c1f8ef160e21b8152600481019290925260248201526044016109bf565b50506020820151151580611fc85750604082015115155b15612025578815158a6001600160a01b03167fcd89ab71e4fff717bc4b3f6f54c4ceafe7ca140db3cbc7b783548a2378c4bcbe8460200151856040015160405161201c929190918252602082015260400190565b60405180910390a35b61202f84846141c6565b8051604084015160095461204c916001600160801b03169061577c565b612056919061580f565b60095561206288611b16565b8351849061207190839061578f565b6001600160801b031690525061209061208b89888c614291565b611b16565b836020018181516120a1919061578f565b6001600160801b031690525080516120b890611b16565b6001600160801b031660408401526001600160401b03421660608401526120df83856142c2565b6120e984846142f8565b6001600160a01b038a165f9081526019602090815260408083208c1515845282528083208651928701516001600160801b03938416600160801b91851682021782559187015160018201805460608a01519286166001600160c01b0319909116176001600160401b039092168402919091179055608087015160a08801519084169316909102919091176002909101556121c48a61218b57866020015161218e565b86515b6001600160801b03166121b960075489604001516001600160401b0316670de0b6b3a7640000613912565b808218908211021890565b855490915081808211156121f457604051631ad2d59b60e01b8152600481019290925260248201526044016109bf565b50506101608601516040850151906001600160801b03808216908316101561224257604051635a95ce8f60e01b81526001600160801b039283166004820152911660248201526044016109bf565b5050612261848b898960e0015161ffff168a60c0015161ffff166143a5565b8915158b6001600160a01b03167f068fd7e47bc720a0cdc70aa9432d25f2c67fb9ede6ffd032a829d62b26ae5d7b8b8b8b886060015189608001518b5f01518c604001516040516122ef979695949392919096875260208701959095526040860193909352606085019190915260808401526001600160801b0390811660a08401521660c082015260e00190565b60405180910390a35050505050505050505050565b61233d6040518060e001604052805f81526020015f81526020015f81526020015f81526020015f81526020015f81526020015f81525090565b6001600160a01b0387165f9081526019602090815260408083208915158452825291829020825160c08101845281546001600160801b03808216808452600160801b92839004821695840195909552600184015480821696840196909652948190046001600160401b0316606083015260029092015493841660808201529204600f0b60a0830152889088906123f9576040516345e40db960e11b81526001600160a01b039092166004830152151560248201526044016109bf565b505060408051610100810182526001600160a01b038a168152881515602082015282515f928201906001600160801b0316808a11908a180289188152602001878152602001868152602001856002811115612456576124566157cc565b81525f6020820181905260409182018190528451918301516001600160801b0390921690911460c083015290915061248e828461447d565b90505f6124a884604001516001600160801b031683613c1c565b90508260c001516124f157602081015160408501519080156124ee57604051632c1f8ef160e21b81526001600160801b03909216600483015260248201526044016109bf565b50505b60208201511515806125065750604082015115155b15612563578915158b6001600160a01b03167fcd89ab71e4fff717bc4b3f6f54c4ceafe7ca140db3cbc7b783548a2378c4bcbe8460200151856040015160405161255a929190918252602082015260400190565b60405180910390a35b604080840151865282516020870152606080840151878301526080840151818801529082015160a087015281015160c086015280516125a590849086906147a4565b60808601525f8660028111156125bd576125bd6157cc565b03612655578915158b6001600160a01b03167f69f7df3f066d4bddb8a8f21c3381f50392d787a0a29c4e36dc03d840cd0a05dc85604001518a865f0151876060015188608001518c60800151896040015160405161264c9796959493929190968752602087019590955260408601939093526060850191909152608084015260a083015260c082015260e00190565b60405180910390a35b505050509695505050505050565b5f5f7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03166327552f6d7f00000000000000000000000000000000000000000000000000000000000000008787876040518563ffffffff1660e01b81526004016126d79493929190615ad9565b6040805180830381865afa1580156126f1573d5f5f3e3d5ffd5b505050506040513d601f19601f820116820180604052508101906127159190615be0565b909250905061272261276d565b6017829055601881905560408051838152602081018390527f945c1c4e99aa89f648fbfe3df471b916f719e16d960fcec0737d4d56bd696838910160405180910390a1935093915050565b6016545f90612785906001600160401b03164261577c565b9050805f036127915750565b5f5f5f5f61279e856133d0565b60148490556015839055600c82905560118190556016805467ffffffffffffffff1916426001600160401b0316179055604080518581526020810185905290810183905260608101829052939750919550935091507fb83c7e937be0ce352823f8301c14549fc8af60d5767d5f9b70227636608070759060800160405180910390a15f61282a86614b9d565b905080156128f5578060085f828254612843919061577c565b925050819055508060075f82825461285b919061580f565b9091555061286a905081611b16565b6021805460109061288c908490600160801b90046001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055507f5eec77d9e91119545e011366d68748d275f35f7f1900bc9995632c6cac661014816007546040516128ec929190918252602082015260400190565b60405180910390a15b505050505050565b60408101516001600160401b03161580159061292e5750670de0b6b3a764000081604001516001600160401b031611155b6001906129515760405163581bbb4760e11b81526004016109bf91815260200190565b5060a08101516001600160401b031615801590612987575080608001516001600160401b03168160a001516001600160401b0316105b80156129ac575080606001516001600160401b031681608001516001600160401b0316105b80156129cc5750670de0b6b3a764000081606001516001600160401b0316105b6002906129ef5760405163581bbb4760e11b81526004016109bf91815260200190565b5060648160c0015161ffff161115600390612a205760405163581bbb4760e11b81526004016109bf91815260200190565b5061010081015161ffff1615801590612a4957508060e0015161ffff1681610100015161ffff16105b8015612a5f57506127108160e0015161ffff1611155b600490612a825760405163581bbb4760e11b81526004016109bf91815260200190565b5080610100015161ffff1681610120015161ffff1610600590612abb5760405163581bbb4760e11b81526004016109bf91815260200190565b50806101a001516001600160801b03168161018001516001600160801b03161115600690612aff5760405163581bbb4760e11b81526004016109bf91815260200190565b506102208101516007906001600160801b0316612b325760405163581bbb4760e11b81526004016109bf91815260200190565b50600a81610140015163ffffffff1610158015612b5d57506201518081610140015163ffffffff1611155b600890612b805760405163581bbb4760e11b81526004016109bf91815260200190565b506424ea4122ae816101c001516001600160401b03161115600990612bbb5760405163581bbb4760e11b81526004016109bf91815260200190565b50650286c0752c718161020001516001600160401b031611158015612bf257506302653766816101e001516001600160401b031611155b600a90612c155760405163581bbb4760e11b81526004016109bf91815260200190565b5064012a05f200816101a001516001600160801b03161115600b90612c505760405163581bbb4760e11b81526004016109bf91815260200190565b50678ac7230489e800008161024001516001600160801b031611158015612c8e5750683635c9adc5dea000008161016001516001600160801b031611155b600c90612cb15760405163581bbb4760e11b81526004016109bf91815260200190565b50805160208201516001600160801b03918216600160801b9183168202176001556040830151600280546060860151608087015160a08801516001600160401b039586166fffffffffffffffffffffffffffffffff1994851617600160401b938716840217881691861687026001600160c01b031691909117600160c01b918616919091021790925560c08601516003805460e08901516101008a01516101208b01516101408c01516101608d015161ffff97881663ffffffff199096169590951762010000948816949094029390931767ffffffff000000001916600160201b9287169290920267ffff000000000000191691909117600160301b95909116949094029390931768010000000000000000600160e01b03191663ffffffff90931685026fffffffffffffffffffffffffffffffff60601b191692909217600160601b928816929092029190911790556101808601516101a08701519086169086168502176004556101c0860151600580546101e08901516102008a015167ffffffffffffffff60801b199488169290951691909117908616909402939093171692168084029290921790556102208401516102408501519084169316909102919091176006555f90612e8390614bca565b9050612ea860145482612e9590615c02565b8082129082180218828113818418021890565b6014556040517fc7f36dc8e3119a25b581eae687b05812e2a091f775868e748400edb677136f9590612edb90849061533a565b60405180910390a15050565b5f5f5f5f612ef485614bf6565b915091505f8113612f05575f612f07565b805b5f8313612f14575f612f16565b825b612f20919061580f565b9250825f03612f3557505f9485945092505050565b6007548015612f5657612f5184670de0b6b3a764000083613912565b612f59565b5f195b9450505050915091565b5f8415612f9f57612f7384614bca565b612f8e612f898585670de0b6b3a7640000613912565b614bca565b612f989190615c1c565b9050612fcb565b612fb5612f898484670de0b6b3a7640000614c3a565b612fbe85614bca565b612fc89190615c1c565b90505b949350505050565b6007546002545f9190600160c01b90046001600160401b0316826130008383670de0b6b3a7640000613912565b9050808511613014575f935050505061155c565b6002545f9061303d908590600160401b90046001600160401b0316670de0b6b3a7640000613912565b90505f81871161305557670de0b6b3a7640000613068565b61306882670de0b6b3a764000089613912565b90505f61307e8583670de0b6b3a7640000613912565b61309090670de0b6b3a764000061577c565b90505f6130af6130a0868b61577c565b670de0b6b3a764000084614c3a565b90508981106130c7578a97505050505050505061155c565b6130e06130d58c838d614c3a565b8c8111818e18021890565b9b9a5050505050505050505050565b5f80546001600160a01b0319166001600160a01b0383169081179091556040519081527f2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad90602001610b24565b5f8161314957600f61161e565b600a92915050565b6016545f90819061316b906001600160401b03164261577c565b90505f5f5f613179846133d0565b6040805160a08082018352600a548252600b54602080840191909152600c5483850152600d54606080850191909152600e5460808086019190915285519384018652600f5484526010549284019290925260115494830194909452601254938201939093526013549281019290925293975091955093509091505f6131fd87614b9d565b60075461320a919061580f565b90505f61321682614bca565b905061324c670de0b6b3a7640000856060015188875f01516132389190615c3b565b613242919061577c565b612f899190615c66565b6132569082615c79565b9050613278670de0b6b3a7640000846060015187865f01516132389190615c3b565b6132829082615c79565b90505f836080015188613297865f0151614bca565b6132a19190615c98565b6132ab9190615c1c565b8560800151896132bd885f0151614bca565b6132c79190615c98565b6132d19190615c1c565b6132db9190615c1c565b90506132e681614c66565b6132f09083615c79565b91505f5f6132fd8d614bf6565b915091505f5f821361330f575f613311565b815b5f841361331e575f613320565b835b61332a919061580f565b90505f5f831261333a575f61333c565b825b5f8512613349575f61334b565b845b6133559190615c79565b6002549091505f90613381908990600160401b90046001600160401b0316670de0b6b3a7640000613912565b9050613394818411848318028418614bca565b61339e9088615c1c565b96506133aa8288615c1c565b96505f87136133b9575f6133bb565b865b9e505050505050505050505050505050919050565b600a54600f54600c546011545f9384938685036133f8576014546015549550955050506135be565b60408051610260810182526001546001600160801b038082168352600160801b91829004811660208401526002546001600160401b0380821695850195909552600160401b8082048616606086015283820486166080860152600160c01b909104851660a085015260035461ffff80821660c0870152620100008204811660e0870152600160201b82048116610100870152600160301b82041661012086015263ffffffff82820416610140860152600160601b9004821661016085015260045480831661018086015283900482166101a08501526005548086166101c086015290810485166101e085018190529083900490941661020084015260065480821661022085018190529290041661024083015290915f9161351c9186918691614cbc565b90505f61353b601454838c8661020001516001600160401b0316614d35565b601554909a5090915061354f908290615c79565b97505f60075490508a6135718783876101c001516001600160401b0316614e99565b61357b9190615c3b565b613585908961580f565b97508a6135a18683876101c001516001600160401b0316614e99565b6135ab9190615c3b565b6135b5908861580f565b96505050505050505b9193509193565b6136006040518060e001604052805f81526020015f81526020015f81526020015f81526020015f81526020015f81526020015f151581525090565b60408051610260810182526001546001600160801b038082168352600160801b9182900481166020808501919091526002546001600160401b0380821696860196909652600160401b8082048716606087015284820487166080870152600160c01b909104861660a086015260035461ffff80821660c0880152620100008204811660e0880152600160201b82048116610100880152600160301b82041661012087015263ffffffff82820416610140870152600160601b9004831661016086015260045480841661018087015284900483166101a08601526005548087166101c087015290810486166101e0860152839004909416610200840152600654808216610220850152919091048116610240830152885192890151919261372d928992918216911688612f63565b825261373b87878686613b01565b60408401526020830152865160c0820151613763916001600160801b03169061ffff16613ba2565b606083015281515f908112613779578251613789565b613789612f89845f015188614ecc565b90506137988360600151614bca565b83604001516137aa8560200151614bca565b836137c18c604001516001600160801b0316614bca565b6137cb9190615c79565b6137d59190615c1c565b6137df9190615c1c565b6137e99190615c1c565b6080840152875161010083015161380d916001600160801b03169061ffff16613ba2565b60a0840181905261381d90614bca565b60808401511260c084015250909695505050505050565b805f0361383e5750565b61384781611b16565b601d8054601090613869908490600160801b90046001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b03160217905550610ff433827f00000000000000000000000000000000000000000000000000000000000000006001600160a01b0316611b4d9092919063ffffffff16565b7f9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f005c1561190a57604051633ee5aeb560e01b815260040160405180910390fd5b80825d5050565b82820281838583041485151702613999575f198385098181108201900382848609835f03841682851161394c5763ae47f7025f526004601cfd5b93849004938382119092035f83900383900460010102920304176002600383028118808402820302808402820302808402820302808402820302808402820302808402909103020261155c565b0492915050565b60405163a9059cbb60e01b5f8181526001600160a01b038616600452602485905291602083604481808b5af1925060015f511483166139f65783831516156139ea573d5f823e3d81fd5b5f873b113d1516831692505b60405250949350505050565b6040516001600160a01b038085166024830152831660448201526001600160e01b0319821660648201525f908190819060840160408051601f19818403018152918152602080830180516001600160e01b031663b700961360e01b1781525f808052918290528351939450919290918a5afa15613a8a575f516020805191945081901c150291505b5094509492505050565b6040516323b872dd60e01b5f8181526001600160a01b038781166004528616602452604485905291602083606481808c5af1925060015f51148316613af0578383151615613ae4573d5f823e3d81fd5b5f883b113d1516831692505b604052505f60605295945050505050565b5f5f855f01516001600160801b03165f03613b2057505f905080613b99565b613b5586608001516001600160801b031685613b3c919061577c565b87516001600160801b0316670de0b6b3a7640000614c3a565b91505f8660a00151600f0b84613b6b9190615c1c565b9050613b9586613b8357613b7e82615c02565b613b85565b815b88516001600160801b0316614f2c565b9150505b94509492505050565b5f61155c8383612710614c3a565b5f825f03613bbf57505f612fcb565b613bf2600a5f0154600f5f01548787878761018001516001600160801b0316886101a001516001600160801b0316614f79565b90505f811315612fcb5760085480821115613c1357613c1081614bca565b91505b50949350505050565b613c4360405180608001604052805f81526020015f81526020015f81526020015f81525090565b6007548251601a919085905f9081908112613c5e575f613c61565b86515b90505f5f886040015112613c75575f613c83565b8760400151613c8390615c02565b6002549091505f90613caf908790600160401b90046001600160401b0316670de0b6b3a7640000613912565b905080613cbc838561580f565b1115613d5b57613cda81613cd0848661580f565b61208b919061577c565b6007880180545f90613cf69084906001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b0316021790555080831115613d3157809250613d2e83614bca565b89525b8115613d5b57613d41838261577c565b9150613d4c82614bca565b613d5590615c02565b60408a01525b5f613d66838561580f565b9050613d72818761580f565b95508315613dcc57613d8384611b16565b600289018054601090613da7908490600160801b90046001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055505b8215613e2457613ddb83611b16565b600189018054601090613dff908490600160801b90046001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055505b5f8a608001511315613eab5760808a0151613e3f818861580f565b96508060085f828254613e52919061577c565b90915550613e61905081611b16565b60048a018054601090613e85908490600160801b90046001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b03160217905550505b5f5f8b5f01511215613f2857613ece878c5f0151613ec890615c02565b8c615081565b97509050613edc818761580f565b9550613ee781611b16565b60028a0180545f90613f039084906001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055505b5f8b604001511315613f9d57613f43878c604001518c615081565b97509050613f51818761580f565b9550613f5c81611b16565b60018a0180545f90613f789084906001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055505b60208b01511561401657613fb6878c602001518c615081565b97509050613fc4818761580f565b9550613fcf81611b16565b89548a90601090613ff1908490600160801b90046001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055505b60608b0151156140875761402f878c606001518c615081565b9750905061403d818761580f565b955061404881611b16565b89548a905f906140629084906001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055505b60208a015160408b015260808b01515f1315614118576140af878c60800151613ec890615c02565b80985081925050508060085f8282546140c8919061580f565b909155506140d7905081611b16565b60048a0180545f906140f39084906001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055505b60a08b0151156141445760a08b015180881190881802871860608b01819052614141908861577c565b96505b60408a01511561419c5761415b8a60400151611b16565b60038a0180545f906141779084906001600160801b031661578f565b92506101000a8154816001600160801b0302191690836001600160801b031602179055505b816141a7878a61580f565b6141b1919061577c565b60075550505092865250939695505050505050565b80516001600160801b03165f036141db575050565b805f01516001600160801b0316825f015f8282546141f9919061577c565b9250508190555080602001516001600160801b0316826001015f828254614220919061577c565b909155505060808101518151614242916001600160801b039081169116615c3b565b826003015f828254614254919061577c565b909155505060a0810151815161427691600f0b906001600160801b0316615c98565b826004015f8282546142889190615c1c565b90915550505050565b5f816142af576142aa84670de0b6b3a764000085614c3a565b612fcb565b612fcb84670de0b6b3a764000085613912565b6142cf8160020154611b16565b6001600160801b031660808301526015546142e9906150bd565b600f0b60a09092019190915250565b805f01516001600160801b0316825f015f828254614316919061580f565b9250508190555080602001516001600160801b0316826001015f82825461433d919061580f565b90915550506080810151815161435f916001600160801b039081169116615c3b565b826003015f828254614371919061580f565b909155505060a0810151815161439391600f0b906001600160801b0316615c98565b826004015f8282546142889190615c79565b5f6143cb85875f01516001600160801b031688602001516001600160801b031687612f63565b90505f6143e7612f89885f01516001600160801b031685613ba2565b5f83126143f4575f6143f6565b825b61440c89604001516001600160801b0316614bca565b6144169190615c79565b6144209190615c1c565b90505f614439885f01516001600160801b031686613ba2565b905061444481614bca565b8212158282909161447157604051634de0b51760e11b8152600481019290925260248201526044016109bf565b50505050505050505050565b6144b06040518060c001604052805f81526020015f81526020015f81526020015f81526020015f81526020015f81525090565b60408051610260810182526001546001600160801b038082168352600160801b9182900481166020808501919091526002546001600160401b0380821696860196909652600160401b8082048716606087015284820487166080870152600160c01b909104861660a086015260035461ffff80821660c0880152620100008204811660e0880152600160201b82048116610100880152600160301b82041661012087015263ffffffff82820416610140870152600160601b9004831661016086015260045480841661018087015284900483166101a08601526005548087166101c087015290810486166101e08601528390049094166102008401526006548082166102208501529190910416610240820152908401516145e29084906145d68161313c565b60020154601554613b01565b8360200184604001828152508281525050505f6146228560200151855f01516001600160801b031686602001516001600160801b03168860800151612f63565b90508460c00151156146495780835260208401516001600160801b031660e08601526146ca565b614664818660400151865f01516001600160801b03166150f1565b8352602085015161469c5761469784602001516001600160801b03168660400151865f01516001600160801b0316613912565b6146c4565b6146c484602001516001600160801b03168660400151865f01516001600160801b0316614c3a565b60e08601525b82515f12156146ea576146e7612f89845f01518760800151614ecc565b83525b5f8560a001516002811115614701576147016157cc565b036147425761471c85604001518360c0015161ffff16613ba2565b60608401526020850151604086015161473891905f9085613bb0565b608084015261479c565b60018560a00151600281111561475a5761475a6157cc565b0361479c5761477585604001518360c0015161ffff16613ba2565b60608401526040850151610120830151614796919061ffff16612710613912565b60a08401525b505092915050565b5f5f6147b3856020015161313c565b90506147bf81856141c6565b8460c00151156148365783604001516001600160801b031660095f8282546147e7919061577c565b909155505084516001600160a01b03165f908152601960209081526040808320828901511515845290915281208181556001810180546001600160c01b0319169055600201555081905061155c565b5f8560a00151600281111561484d5761484d6157cc565b036148a5578285606001511115614891578283866060015161486f919061577c565b604051632c1f8ef160e21b8152600481019290925260248201526044016109bf565b606085015191506148a2828461577c565b92505b8284604001516001600160801b03166009546148c1919061577c565b6148cb919061580f565b60095560408501516148dc90611b16565b845185906148eb908390615cc7565b6001600160801b031690525060e085015161490590611b16565b846020018181516149169190615cc7565b6001600160801b031690525061492b83611b16565b6001600160801b031660408501526001600160401b034216606085015261495284826142c2565b61495c81856142f8565b84516001600160a01b03165f908152601960209081526040808320828901511515845282528083208751928801516001600160801b03938416600160801b91851682021782559188015160018201805460608b01519286166001600160c01b0319909116176001600160401b039092168402919091179055608088015160a08901519084169316909102919091176002909101558560a001516002811115614a0657614a066157cc565b03614b955760408051610260810182526001546001600160801b038082168352600160801b91829004811660208401526002546001600160401b0380821685870152600160401b8083048216606087015284830482166080870152600160c01b909204811660a086015260035461ffff80821660c0880152620100008204811660e0880152600160201b82048116610100880152600160301b82041661012087015263ffffffff83820416610140870152600160601b90048316610160860181905260045480851661018088015285900484166101a08701526005548083166101c088015292830482166101e087015291849004166102008501526006548083166102208601529290920481166102408401529287015191928216811115614b5457604051635a95ce8f60e01b81526001600160801b039283166004820152911660248201526044016109bf565b50505f835f03614b6957816101000151614b6f565b8160e001515b61ffff169050614b928688602001518960800151848660c0015161ffff166143a5565b50505b509392505050565b6008545f9062093a808310614bb25792915050565b62093a80614bc08483615c3b565b61155c9190615c66565b5f6001600160ff1b03821115611b495760405163123baf0360e11b8152600481018390526024016109bf565b5f5f825f03614c0957505f928392509050565b600a54600b54614c1c9160019186612f63565b9150614c335f600f5f0154600f6001015486612f63565b9050915091565b5f614c46848484613912565b9050818385091561155c576001018061155c5763ae47f7025f526004601cfd5b5f5f8212614c805761161e670de0b6b3a764000083615ce6565b670de0b6b3a7640000600181614c9585615c02565b614c9f9190615c79565b614ca99190615c1c565b614cb39190615ce6565b61161e90615c02565b5f80848611808203878703180190505f614cf6614ce283670de0b6b3a764000088613912565b670de0b6b3a7640000808218908211021890565b90505f614d0f612f898387670de0b6b3a7640000613912565b905086881015614d2757614d2281615c02565b614d29565b805b98975050505050505050565b5f5f5f614d4184614bca565b9050614d5087612e9583615c02565b9650845f03614d65575f879250925050613b99565b5f614d6f86614bca565b9050865f03614d8e57614d828189615c98565b88935093505050613b99565b5f614d998289615c98565b614da3908a615c79565b905082811315614df8575f614db88a85615c1c565b9050614dc5896002615c98565b614dcf8280615c98565b614dd99190615ce6565b614de38486615c98565b614ded9190615c1c565b955083945050614e8d565b614e0183615c02565b811215614e66575f614e138a85615c79565b9050614e2189600119615c98565b614e2b8280615c98565b614e359190615ce6565b83614e3f86615c02565b614e499190615c98565b614e539190615c79565b9550614e5e84615c02565b945050614e8d565b600282614e73838c615c79565b614e7d9190615c98565b614e879190615ce6565b94508093505b50505094509492505050565b5f835f03614ea857505f61155c565b821580614eb55750828410155b15614ec157508061155c565b612fcb828585614c3a565b5f5f614ed783612ee7565b6007546002549193505f9250614f0591600160401b90046001600160401b0316670de0b6b3a7640000613912565b9050808211614f1857849250505061161e565b614f23858284613912565b95945050505050565b5f5f8312614f5157614f4a612f898484670de0b6b3a7640000614c3a565b905061161e565b614f70612f8960ff85901d808601185b84670de0b6b3a7640000613912565b61155c90615c02565b5f87878715614fa75786614f9657614f91868b61577c565b614fa0565b614fa0868b61580f565b9150614fc8565b86614fbb57614fb6868a61577c565b614fc5565b614fc5868a61580f565b90505b888a115f8181038c8c0318820191838511918290038585031882019190159015148015615047578282101561502a57615006612f89838a600161512d565b615014612f89858b5f61512d565b61501e9190615c1c565b95505050505050615076565b615039612f898389600161512d565b615014612f89858a5f61512d565b615056612f898389600161512d565b615064612f89858b5f61512d565b61506e9190615c1c565b955050505050505b979650505050505050565b8282188284110283185f615095828561577c565b836020018181516150a6919061580f565b9052506150b3828661577c565b9050935093915050565b80600f81900b81146150ec5760405163327269a760e01b815260806004820152602481018390526044016109bf565b919050565b5f5f841261510e57615107612f89858585613912565b905061155c565b615124612f8960ff86901d808701188585614c3a565b612fcb90615c02565b5f831580615139575082155b1561514557505f61155c565b8115615170576151076151618586670de0b6b3a7640000614c3a565b84670de0b6b3a7640000614c3a565b612fcb614f618586670de0b6b3a7640000613912565b80356001600160a01b03811681146150ec575f5ffd5b5f5f604083850312156151ad575f5ffd5b823591506151bd60208401615186565b90509250929050565b803580151581146150ec575f5ffd5b5f602082840312156151e5575f5ffd5b61155c826151c6565b5f5f828403610140811215615201575f5ffd5b61012081121561520f575f5ffd5b5091936101208501359350915050565b5f5f83601f84011261522f575f5ffd5b5081356001600160401b03811115615245575f5ffd5b6020830191508360208260051b850101111561525f575f5ffd5b9250929050565b5f5f5f60408486031215615278575f5ffd5b83356001600160401b0381111561528d575f5ffd5b6152998682870161521f565b909790965060209590950135949350505050565b5f602082840312156152bd575f5ffd5b5035919050565b5f6102608284031280156152d6575f5ffd5b509092915050565b5f5f5f5f606085870312156152f1575f5ffd5b6152fa85615186565b9350615308602086016151c6565b925060408501356001600160401b03811115615322575f5ffd5b61532e8782880161521f565b95989497509550505050565b81516001600160801b031681526102608101602083015161536660208401826001600160801b03169052565b50604083015161538160408401826001600160401b03169052565b50606083015161539c60608401826001600160401b03169052565b5060808301516153b760808401826001600160401b03169052565b5060a08301516153d260a08401826001600160401b03169052565b5060c08301516153e860c084018261ffff169052565b5060e08301516153fe60e084018261ffff169052565b5061010083015161541661010084018261ffff169052565b5061012083015161542e61012084018261ffff169052565b5061014083015161544861014084018263ffffffff169052565b506101608301516154656101608401826001600160801b03169052565b506101808301516154826101808401826001600160801b03169052565b506101a083015161549f6101a08401826001600160801b03169052565b506101c08301516154bc6101c08401826001600160401b03169052565b506101e08301516154d96101e08401826001600160401b03169052565b506102008301516154f66102008401826001600160401b03169052565b506102208301516155136102208401826001600160801b03169052565b506102408301516155306102408401826001600160801b03169052565b5092915050565b5f60208284031215615547575f5ffd5b61155c82615186565b5f5f5f60608486031215615562575f5ffd5b61556b84615186565b9250615579602085016151c6565b929592945050506040919091013590565b81516001600160801b03168152610200810160208301516155b660208401826001600160801b03169052565b5060408301516155d160408401826001600160801b03169052565b5060608301516155ec60608401826001600160801b03169052565b50608083015161560760808401826001600160801b03169052565b5060a083015161562260a08401826001600160801b03169052565b5060c083015161563d60c08401826001600160801b03169052565b5060e083015161565860e08401826001600160801b03169052565b506101008301516156756101008401826001600160801b03169052565b506101208301516156926101208401826001600160801b03169052565b506101408301516156af6101408401826001600160801b03169052565b506101608301516156cc6101608401826001600160801b03169052565b506101808301516156e96101808401826001600160801b03169052565b506101a08301516157066101a08401826001600160801b03169052565b506101c08301516157236101c08401826001600160801b03169052565b506101e08301516155306101e08401826001600160801b03169052565b5f5f60408385031215615751575f5ffd5b61575a83615186565b91506151bd602084016151c6565b634e487b7160e01b5f52601160045260245ffd5b8181038181111561161e5761161e615768565b6001600160801b03818116838216019081111561161e5761161e615768565b5f602082840312156157be575f5ffd5b81356005811061155c575f5ffd5b634e487b7160e01b5f52602160045260245ffd5b80356001600160801b03811681146150ec575f5ffd5b5f60208284031215615806575f5ffd5b61155c826157e0565b8082018082111561161e5761161e615768565b60405161026081016001600160401b038111828210171561585157634e487b7160e01b5f52604160045260245ffd5b60405290565b80356001600160401b03811681146150ec575f5ffd5b803561ffff811681146150ec575f5ffd5b803563ffffffff811681146150ec575f5ffd5b5f6102608284031280156158a3575f5ffd5b506158ac615822565b6158b5836157e0565b81526158c3602084016157e0565b60208201526158d460408401615857565b60408201526158e560608401615857565b60608201526158f660808401615857565b608082015261590760a08401615857565b60a082015261591860c0840161586d565b60c082015261592960e0840161586d565b60e082015261593b610100840161586d565b61010082015261594e610120840161586d565b610120820152615961610140840161587e565b61014082015261597461016084016157e0565b61016082015261598761018084016157e0565b61018082015261599a6101a084016157e0565b6101a08201526159ad6101c08401615857565b6101c08201526159c06101e08401615857565b6101e08201526159d36102008401615857565b6102008201526159e661022084016157e0565b6102208201526159f961024084016157e0565b6102408201529392505050565b5f6001600160801b0382166001600160801b038103615a2757615a27615768565b60010192915050565b5f5f85851115615a3e575f5ffd5b83861115615a4a575f5ffd5b5050820193919092039150565b80356001600160e01b03198116906004841015615530576001600160e01b031960049490940360031b84901b1690921692915050565b81835281816020850137505f828201602090810191909152601f909101601f19169091010190565b6001600160a01b03841681526040602082018190525f90612fc89083018486615a8d565b84815260606020820181905281018390525f6080600585901b830181019083018683607e1936839003015b88821015615bca57868503607f190184528235818112615b22575f5ffd5b8a016001600160a01b03615b3582615186565b168652602081810135908701526001600160401b03615b5660408301615857565b1660408701526060810135601e19823603018112615b72575f5ffd5b016020810190356001600160401b03811115615b8c575f5ffd5b803603821315615b9a575f5ffd5b60806060880152615baf608088018284615a8d565b96505050602083019250602084019350600182019150615b04565b5050505060409290920192909252949350505050565b5f5f60408385031215615bf1575f5ffd5b505080516020909101519092909150565b5f600160ff1b8201615c1657615c16615768565b505f0390565b8181035f83128015838313168383128216171561553057615530615768565b808202811582820484141761161e5761161e615768565b634e487b7160e01b5f52601260045260245ffd5b5f82615c7457615c74615c52565b500490565b8082018281125f83128015821682158216171561479c5761479c615768565b8082025f8212600160ff1b84141615615cb357615cb3615768565b818105831482151761161e5761161e615768565b6001600160801b03828116828216039081111561161e5761161e615768565b5f82615cf457615cf4615c52565b600160ff1b82145f1984141615615d0d57615d0d615768565b5005905660e06040526001600655348015610014575f5ffd5b50604051612aa5380380612aa5833981016040819052610033916102da565b82848383600361004383826103f3565b50600461005082826103f3565b5050505f5f610064836100b960201b60201c565b9150915081610074576012610076565b805b60ff1660a05250506001600160a01b0316608052610093816100ec565b503360c08190526100b0906001600160a01b038616905f19610140565b505050506104b1565b63313ce56760e01b5f818152908190602082600481875afa5f51601f3d1190911661010082101695908602945092505050565b600580546001600160a01b0319166001600160a01b0383169081179091556040519081527f2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad9060200160405180910390a150565b61014c8383835f6101c4565b6101bf5761015d83835f60016101c4565b61018a57604051635274afe760e01b81526001600160a01b03841660048201526024015b60405180910390fd5b61019783838360016101c4565b6101bf57604051635274afe760e01b81526001600160a01b0384166004820152602401610181565b505050565b60405163095ea7b360e01b5f8181526001600160a01b038616600452602485905291602083604481808b5af1925060015f5114831661021a57838315161561020e573d5f823e3d81fd5b5f873b113d1516831692505b60405250949350505050565b6001600160a01b038116811461023a575f5ffd5b50565b634e487b7160e01b5f52604160045260245ffd5b5f82601f830112610260575f5ffd5b81516001600160401b038111156102795761027961023d565b604051601f8201601f19908116603f011681016001600160401b03811182821017156102a7576102a761023d565b6040528181528382016020018510156102be575f5ffd5b8160208501602083015e5f918101602001919091529392505050565b5f5f5f5f608085870312156102ed575f5ffd5b84516102f881610226565b602086015190945061030981610226565b60408601519093506001600160401b03811115610324575f5ffd5b61033087828801610251565b606087015190935090506001600160401b0381111561034d575f5ffd5b61035987828801610251565b91505092959194509250565b600181811c9082168061037957607f821691505b60208210810361039757634e487b7160e01b5f52602260045260245ffd5b50919050565b601f8211156101bf57828211156101bf57805f5260205f20601f840160051c60208510156103c857505f5b90810190601f840160051c035f5b818110156103eb575f838201556001016103d6565b505050505050565b81516001600160401b0381111561040c5761040c61023d565b6104208161041a8454610365565b8461039d565b6020601f821160018114610452575f831561043b5750848201515b5f19600385901b1c1916600184901b1784556104aa565b5f84815260208120601f198516915b828110156104815787850151825560209485019460019092019101610461565b508482101561049e57868401515f19600387901b60f8161c191681555b505060018360011b0184555b5050505050565b60805160a05160c05161257661052f5f395f81816103aa015281816105f90152818161086101528181610a0401528181610c4e01528181610e7e01528181610fd8015261117701525f6109d301525f81816102e70152818161098e01528181610b3401528181610d6e0152818161132701526115bd01526125765ff3fe608060405234801561000f575f5ffd5b506004361061021e575f3560e01c806380f556051161012a578063ba087652116100b4578063c6e6f59211610079578063c6e6f592146105ab578063ce96cb7714610332578063d905777e14610332578063dd62ed3e146105be578063ef8b30f7146105ab575f5ffd5b8063ba0876521461042e578063bf7e214f1461044f578063c3cb99cb14610460578063c58343ef14610469578063c63d75b614610332575f5ffd5b8063a9059cbb116100fa578063a9059cbb146103f5578063af4dbb4e14610408578063b3d7f6b91461041b578063b460af941461042e578063b7dce2d01461043c575f5ffd5b806380f55605146103a55780638fb36037146103cc57806394bf804d1461034e57806395d89b41146103ed575f5ffd5b806338d52e0f116101ab5780636a84a9851161017b5780636a84a985146103455780636e553f651461034e578063704743ee1461036157806370a082311461036a5780637a9e5e4b14610392575f5ffd5b806338d52e0f146102e55780633e3cf2541461031f578063402d267d146103325780634cdad50614610252575f5ffd5b80630a28a477116101f15780630a28a4771461028857806318160ddd1461029b57806323b872dd146102a35780633015394c146102b6578063313ce567146102cb575f5ffd5b806301e1d1141461022257806306fdde031461023d57806307a2d13a14610252578063095ea7b314610265575b5f5ffd5b61022a6105f6565b6040519081526020015b60405180910390f35b61024561067c565b6040516102349190611f73565b61022a610260366004611f85565b61070c565b610278610273366004611fb7565b61071d565b6040519015158152602001610234565b61022a610296366004611f85565b610734565b60025461022a565b6102786102b1366004611fdf565b610740565b6102c96102c4366004611f85565b610765565b005b6102d36109cc565b60405160ff9091168152602001610234565b7f00000000000000000000000000000000000000000000000000000000000000005b6040516001600160a01b039091168152602001610234565b61022a61032d366004612019565b6109f7565b61022a610340366004612042565b505f90565b61022a60065481565b61022a61035c36600461205b565b610b6f565b61022a60085481565b61022a610378366004612042565b6001600160a01b03165f9081526020819052604090205490565b6102c96103a0366004612042565b610b89565b6103077f000000000000000000000000000000000000000000000000000000000000000081565b6103d4610c02565b6040516001600160e01b03199091168152602001610234565b610245610c26565b610278610403366004611fb7565b610c35565b61022a610416366004612019565b610c42565b61022a610429366004611f85565b610d9b565b61022a61035c366004612085565b6102c961044a3660046120be565b610da7565b6005546001600160a01b0316610307565b61022a60075481565b610531610477366004611f85565b6040805160c0810182525f80825260208201819052918101829052606081018290526080810182905260a0810191909152505f90815260096020908152604091829020825160c08101845281546001600160a01b0381168252600160a01b810460ff16151593820193909352600160a81b90920467ffffffffffffffff169282019290925260018201546001600160801b038082166060840152600160801b9091048116608083015260029092015490911660a082015290565b60405161023491905f60c08201905060018060a01b03835116825260208301511515602083015267ffffffffffffffff60408401511660408301526001600160801b0360608401511660608301526001600160801b0360808401511660808301526001600160801b0360a08401511660a083015292915050565b61022a6105b9366004611f85565b611358565b61022a6105cc366004612138565b6001600160a01b039182165f90815260016020908152604080832093909416825291909152205490565b5f7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b031663b86150716040518163ffffffff1660e01b8152600401602060405180830381865afa158015610653573d5f5f3e3d5ffd5b505050506040513d601f19601f820116820180604052508101906106779190612160565b905090565b60606003805461068b90612177565b80601f01602080910402602001604051908101604052809291908181526020018280546106b790612177565b80156107025780601f106106d957610100808354040283529160200191610702565b820191905f5260205f20905b8154815290600101906020018083116106e557829003601f168201915b5050505050905090565b5f610717825f611363565b92915050565b5f3361072a81858561139b565b5060019392505050565b5f6107178260016113a8565b5f3361074d8582856113d7565b610758858585611453565b60019150505b9392505050565b61076d6114b0565b5f81815260096020908152604091829020825160c08101845281546001600160a01b038116808352600160a01b820460ff16151594830194909452600160a81b900467ffffffffffffffff169381019390935260018101546001600160801b038082166060860152600160801b909104811660808501526002909101541660a0830152829061081b57604051631f79bbe760e01b815260040161081291815260200190565b60405180910390fd5b50805133906001600160a01b038116821461085c5760405163220984bd60e01b81526001600160a01b03928316600482015291166024820152604401610812565b50505f7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03166352566e936040518163ffffffff1660e01b8152600401606060405180830381865afa1580156108bb573d5f5f3e3d5ffd5b505050506040513d601f19601f820116820180604052508101906108df91906121af565b509150505f81836040015167ffffffffffffffff166108fe91906121fe565b90508042101581906109265760405163a9e6787760e01b815260040161081291815260200190565b5061093184846114e7565b6040805160208082525f90820152339186917f15ff1aa7a69432f2d25bfd1a930e7eab889b29daf52c2b8a3bd61a2ebfa8cbf2910160405180910390a36109778361159c565b825160a08401516109be91906001600160801b03167f00000000000000000000000000000000000000000000000000000000000000005b6001600160a01b031691906115fc565b5050506109c9611631565b50565b5f610677817f0000000000000000000000000000000000000000000000000000000000000000612211565b5f610a006114b0565b5f5f7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03166352566e936040518163ffffffff1660e01b8152600401606060405180830381865afa158015610a5e573d5f5f3e3d5ffd5b505050506040513d601f19601f82011682018060405250810190610a8291906121af565b92505091508015610aa657604051630a9105a360e31b815260040160405180910390fd5b855f03610ac657604051632e11048160e11b815260040160405180910390fd5b838280821015610af257604051634dac79c560e01b815260048101929092526024820152604401610812565b5050610b01600187878761165b565b9250610b0d84876121fe565b60075f828254610b1d91906121fe565b90915550610b6590503330610b32878a6121fe565b7f00000000000000000000000000000000000000000000000000000000000000005b6001600160a01b03169291906117e2565b505061075e611631565b5f60405163d16ffd8360e01b815260040160405180910390fd5b60055433906001600160a01b03168114610bc05760405162d1953b60e31b81526001600160a01b0382166004820152602401610812565b816001600160a01b03163b5f03610bf5576040516361798f2f60e11b81526001600160a01b0383166004820152602401610812565b610bfe82611818565b5050565b6005545f90600160a01b900460ff16610c1a57505f90565b50638fb3603760e01b90565b60606004805461068b90612177565b5f3361072a818585611453565b5f610c4b6114b0565b5f7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03166352566e936040518163ffffffff1660e01b8152600401606060405180830381865afa158015610ca8573d5f5f3e3d5ffd5b505050506040513d601f19601f82011682018060405250810190610ccc91906121af565b50509050845f03610cf057604051632e11048160e11b815260040160405180910390fd5b828180821015610d1c57604051634dac79c560e01b815260048101929092526024820152604401610812565b5050610d2a5f86868661165b565b91508260075f828254610d3d91906121fe565b925050819055508460085f828254610d5591906121fe565b90915550610d669050333087611453565b610d923330857f0000000000000000000000000000000000000000000000000000000000000000610b54565b5061075e611631565b5f610717826001611363565b610daf6114b0565b610dba335f3661186c565b5f83815260096020908152604091829020825160c08101845281546001600160a01b038116808352600160a01b820460ff16151594830194909452600160a81b900467ffffffffffffffff169381019390935260018101546001600160801b038082166060860152600160801b909104811660808501526002909101541660a08301528490610e5f57604051631f79bbe760e01b815260040161081291815260200190565b506040808201519051634bb2834960e01b81525f916001600160a01b037f00000000000000000000000000000000000000000000000000000000000000001691634bb2834991610eb59188918891600401612252565b60408051808303815f875af1158015610ed0573d5f5f3e3d5ffd5b505050506040513d601f19601f82011682018060405250810190610ef49190612360565b509050610f0185836114e7565b8160200151156110f5575f610f2283606001516001600160801b0316611358565b9050801580610f3d575082608001516001600160801b031681105b15610fb457610faf86846371c4efed60e01b848760800151604051602401610f789291909182526001600160801b0316602082015260400190565b60408051601f198184030181529190526020810180516001600160e01b03166001600160e01b031990931692909217909152611965565b6110ef565b60608301516040516328e32c8560e11b81526001600160801b0390911660048201527f00000000000000000000000000000000000000000000000000000000000000006001600160a01b0316906351c6590a906024015f604051808303815f87803b158015611021575f5ffd5b505af1158015611033573d5f5f3e3d5ffd5b50505050611044835f0151826119b0565b82516060840151604080516001600160801b039092168252602082018490526001600160a01b039092169182917fdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7910160405180910390a3606080840151604080516001600160801b039092168252602082018490528101849052339188917f4719d71a3d6b1767f98078bd03019d4af3fc4e9d8b40a52783c193f69d47f457910160405180910390a35b50611310565b5f61110c83606001516001600160801b031661070c565b905082608001516001600160801b031681101561115e5761115986846371c4efed60e01b848760800151604051602401610f789291909182526001600160801b0316602082015260400190565b61130e565b82516040516305fe138b60e01b81526001600160a01b037f000000000000000000000000000000000000000000000000000000000000000016916305fe138b916111be9185916004019182526001600160a01b0316602082015260400190565b5f604051808303815f87803b1580156111d5575f5ffd5b505af19250505080156111e6575060015b61124b573d808015611213576040519150601f19603f3d011682016040523d82523d5f602084013e611218565b606091505b5080515f0361123a576040516350e6719d60e11b815260040160405180910390fd5b611245878583611965565b5061130e565b6112623084606001516001600160801b03166119e4565b82516060840151604080518481526001600160801b0390921660208301526001600160a01b0390921691829182917ffbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db910160405180910390a4606080840151604080516001600160801b039092168252602082018490528101849052339188917f4719d71a3d6b1767f98078bd03019d4af3fc4e9d8b40a52783c193f69d47f457910160405180910390a35b505b611349338360a001516001600160801b03166109ae7f000000000000000000000000000000000000000000000000000000000000000090565b5050611353611631565b505050565b5f610717825f6113a8565b5f61075e61136f6105f6565b61137a9060016121fe565b6113855f600a612465565b60025461139291906121fe565b85919085611a18565b6113538383836001611a65565b5f61075e6113b782600a612465565b6002546113c491906121fe565b6113cc6105f6565b6113929060016121fe565b6001600160a01b038381165f908152600160209081526040808320938616835292905220545f1981101561144d578181101561143f57604051637dc7a0d960e11b81526001600160a01b03841660048201526024810182905260448101839052606401610812565b61144d84848484035f611a65565b50505050565b6001600160a01b03831661147c57604051634b637e8f60e11b81525f6004820152602401610812565b6001600160a01b0382166114a55760405163ec442f0560e01b81525f6004820152602401610812565b611353838383611b37565b6114b8611c5d565b6114e560017f9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f005b90611c9d565b565b5f828152600960209081526040822080546001600160e81b03191681556001810192909255600290910180546001600160801b031916905560a0820151908201516001600160801b039091169061153e575f61154d565b81606001516001600160801b03165b61155791906121fe565b60075f8282546115679190612473565b90915550506020810151610bfe5780606001516001600160801b031660085f8282546115939190612473565b90915550505050565b8060200151156115e157805160608201516109c991906001600160801b03167f00000000000000000000000000000000000000000000000000000000000000006109ae565b6109c930825f015183606001516001600160801b0316611453565b6116098383836001611ca4565b61135357604051635274afe760e01b81526001600160a01b0384166004820152602401610812565b6114e55f7f9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f006114df565b600680545f918261166b83612486565b9190505590506040518060c00160405280336001600160a01b0316815260200186151581526020014267ffffffffffffffff1681526020016116ac86611d06565b6001600160801b031681526020016116c385611d06565b6001600160801b031681526020016116da84611d06565b6001600160801b039081169091525f8381526009602090815260409182902084518154868401518786015167ffffffffffffffff16600160a81b0267ffffffffffffffff60a81b19911515600160a01b026001600160a81b03199093166001600160a01b039094169390931791909117161781556060808601516080808801518716600160801b0291871691909117600184015560a09096015160029092018054929095166001600160801b03199092169190911790935581518915158152908101889052908101869052908101849052339183917f26a2d26a9729caff89f29e26d0ca908bdfdbfdd45a767937528134b0f7568100910160405180910390a3949350505050565b6117f0848484846001611d3d565b61144d57604051635274afe760e01b81526001600160a01b0385166004820152602401610812565b600580546001600160a01b0319166001600160a01b0383169081179091556040519081527f2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad9060200160405180910390a150565b5f5f6118a06118836005546001600160a01b031690565b863061189260045f898b61249e565b61189b916124c5565b611daa565b915091508161195e5763ffffffff81161561193b576005805460ff60a01b198116600160a01b17909155604051634a63ebf760e11b81526001600160a01b03909116906394c7d7ee906118fb908890889088906004016124fd565b5f604051808303815f87803b158015611912575f5ffd5b505af1158015611924573d5f5f3e3d5ffd5b50506005805460ff60a01b191690555061195e9050565b60405162d1953b60e31b81526001600160a01b0386166004820152602401610812565b5050505050565b336001600160a01b0316837f15ff1aa7a69432f2d25bfd1a930e7eab889b29daf52c2b8a3bd61a2ebfa8cbf28360405161199f9190611f73565b60405180910390a36113538261159c565b6001600160a01b0382166119d95760405163ec442f0560e01b81525f6004820152602401610812565b610bfe5f8383611b37565b6001600160a01b038216611a0d57604051634b637e8f60e11b81525f6004820152602401610812565b610bfe825f83611b37565b5f611a45611a2583611e3c565b8015611a4057505f8480611a3b57611a3b612521565b868809115b151590565b611a50868686611e68565b611a5a91906121fe565b90505b949350505050565b6001600160a01b038416611a8e5760405163e602df0560e01b81525f6004820152602401610812565b6001600160a01b038316611ab757604051634a1406b160e11b81525f6004820152602401610812565b6001600160a01b038085165f908152600160209081526040808320938716835292905220829055801561144d57826001600160a01b0316846001600160a01b03167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b92584604051611b2991815260200190565b60405180910390a350505050565b6001600160a01b038316611b61578060025f828254611b5691906121fe565b90915550611bd19050565b6001600160a01b0383165f9081526020819052604090205481811015611bb35760405163391434e360e21b81526001600160a01b03851660048201526024810182905260448101839052606401610812565b6001600160a01b0384165f9081526020819052604090209082900390555b6001600160a01b038216611bed57600280548290039055611c0b565b6001600160a01b0382165f9081526020819052604090208054820190555b816001600160a01b0316836001600160a01b03167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef83604051611c5091815260200190565b60405180910390a3505050565b7f9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f005c156114e557604051633ee5aeb560e01b815260040160405180910390fd5b80825d5050565b60405163a9059cbb60e01b5f8181526001600160a01b038616600452602485905291602083604481808b5af1925060015f51148316611cfa578383151615611cee573d5f823e3d81fd5b5f873b113d1516831692505b60405250949350505050565b5f6001600160801b03821115611d39576040516306dfcc6560e41b81526080600482015260248101839052604401610812565b5090565b6040516323b872dd60e01b5f8181526001600160a01b038781166004528616602452604485905291602083606481808c5af1925060015f51148316611d99578383151615611d8d573d5f823e3d81fd5b5f883b113d1516831692505b604052505f60605295945050505050565b6040516001600160a01b038085166024830152831660448201526001600160e01b0319821660648201525f908190819060840160408051601f19818403018152918152602080830180516001600160e01b031663b700961360e01b1781525f808052918290528351939450919290918a5afa15611e32575f516020805191945081901c150291505b5094509492505050565b5f6002826003811115611e5157611e51612535565b611e5b9190612549565b60ff166001149050919050565b5f5f5f611e758686611f18565b91509150815f03611e9957838181611e8f57611e8f612521565b049250505061075e565b818411611eb057611eb06003851502601118611f34565b5f848688095f868103871696879004966002600389028118808a02820302808a02820302808a02820302808a02820302808a02820302808a02909103029181900381900460010185841190960395909502919093039390930492909217029150509392505050565b5f805f1983850993909202808410938190039390930393915050565b634e487b715f52806020526024601cfd5b5f81518084528060208401602086015e5f602082860101526020601f19601f83011685010191505092915050565b602081525f61075e6020830184611f45565b5f60208284031215611f95575f5ffd5b5035919050565b80356001600160a01b0381168114611fb2575f5ffd5b919050565b5f5f60408385031215611fc8575f5ffd5b611fd183611f9c565b946020939093013593505050565b5f5f5f60608486031215611ff1575f5ffd5b611ffa84611f9c565b925061200860208501611f9c565b929592945050506040919091013590565b5f5f5f6060848603121561202b575f5ffd5b505081359360208301359350604090920135919050565b5f60208284031215612052575f5ffd5b61075e82611f9c565b5f5f6040838503121561206c575f5ffd5b8235915061207c60208401611f9c565b90509250929050565b5f5f5f60608486031215612097575f5ffd5b833592506120a760208501611f9c565b91506120b560408501611f9c565b90509250925092565b5f5f5f604084860312156120d0575f5ffd5b83359250602084013567ffffffffffffffff8111156120ed575f5ffd5b8401601f810186136120fd575f5ffd5b803567ffffffffffffffff811115612113575f5ffd5b8660208260051b8401011115612127575f5ffd5b939660209190910195509293505050565b5f5f60408385031215612149575f5ffd5b61215283611f9c565b915061207c60208401611f9c565b5f60208284031215612170575f5ffd5b5051919050565b600181811c9082168061218b57607f821691505b6020821081036121a957634e487b7160e01b5f52602260045260245ffd5b50919050565b5f5f5f606084860312156121c1575f5ffd5b835160208501516040860151919450925080151581146121df575f5ffd5b809150509250925092565b634e487b7160e01b5f52601160045260245ffd5b80820180821115610717576107176121ea565b60ff8181168382160190811115610717576107176121ea565b81835281816020850137505f828201602090810191909152601f909101601f19169091010190565b604080825281018390525f6060600585901b830181019083018683607e1936839003015b8882101561234557868503605f190184528235818112612294575f5ffd5b8a016001600160a01b036122a782611f9c565b16865260208181013590870152604081013567ffffffffffffffff81168082146122cf575f5ffd5b604088015250606081013536829003601e190181126122ec575f5ffd5b0160208101903567ffffffffffffffff811115612307575f5ffd5b803603821315612315575f5ffd5b6080606088015261232a60808801828461222a565b96505050602083019250602084019350600182019150612276565b50505067ffffffffffffffff85166020850152509050611a5d565b5f5f60408385031215612371575f5ffd5b505080516020909101519092909150565b6001815b60018411156123bd578085048111156123a1576123a16121ea565b60018416156123af57908102905b60019390931c928002612386565b935093915050565b5f826123d357506001610717565b816123df57505f610717565b81600181146123f557600281146123ff5761241b565b6001915050610717565b60ff841115612410576124106121ea565b50506001821b610717565b5060208310610133831016604e8410600b841016171561243e575081810a610717565b61244a5f198484612382565b805f190482111561245d5761245d6121ea565b029392505050565b5f61075e60ff8416836123c5565b81810381811115610717576107176121ea565b5f60018201612497576124976121ea565b5060010190565b5f5f858511156124ac575f5ffd5b838611156124b8575f5ffd5b5050820193919092039150565b80356001600160e01b031981169060048410156124f6576001600160e01b0319600485900360031b81901b82161691505b5092915050565b6001600160a01b03841681526040602082018190525f90611a5a908301848661222a565b634e487b7160e01b5f52601260045260245ffd5b634e487b7160e01b5f52602160045260245ffd5b5f60ff83168061256757634e487b7160e01b5f52601260045260245ffd5b8060ff841606915050929150505660c060405260018055348015610013575f5ffd5b50604051611d0b380380611d0b833981016040819052610032916101b4565b8061003c81610064565b503360808190526001600160a01b03831660a081905261005d915f196100b7565b50506101ec565b5f80546001600160a01b0319166001600160a01b0383169081179091556040519081527f2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad9060200160405180910390a150565b6100c38383835f61013b565b610136576100d483835f600161013b565b61010157604051635274afe760e01b81526001600160a01b03841660048201526024015b60405180910390fd5b61010e838383600161013b565b61013657604051635274afe760e01b81526001600160a01b03841660048201526024016100f8565b505050565b60405163095ea7b360e01b5f8181526001600160a01b038616600452602485905291602083604481808b5af1925060015f51148316610191578383151615610185573d5f823e3d81fd5b5f873b113d1516831692505b60405250949350505050565b6001600160a01b03811681146101b1575f5ffd5b50565b5f5f604083850312156101c5575f5ffd5b82516101d08161019d565b60208401519092506101e18161019d565b809150509250929050565b60805160a051611ac66102455f395f818161018a015281816105f201528181610ac001528181610fb6015261103501525f81816101210152818161046c015281816106cf01528181610d370152610eab0152611ac65ff3fe608060405234801561000f575f5ffd5b50600436106100b1575f3560e01c8063a3d898441161006e578063a3d898441461017c578063b2016bd414610185578063bf7e214f146101ac578063c239dd0e146101bc578063d09ef241146101cf578063f0029279146101ef575f5ffd5b80632a58b330146100b55780633c50e5a4146100d1578063514fcac7146100f45780637a9e5e4b1461010957806380f556051461011c5780638fb360371461015b575b5f5ffd5b6100be60015481565b6040519081526020015b60405180910390f35b6100e46100df36600461155f565b610202565b60405190151581526020016100c8565b61010761010236600461157f565b610313565b005b6101076101173660046115b1565b610628565b6101437f000000000000000000000000000000000000000000000000000000000000000081565b6040516001600160a01b0390911681526020016100c8565b6101636106a0565b6040516001600160e01b031990911681526020016100c8565b6100be60025481565b6101437f000000000000000000000000000000000000000000000000000000000000000081565b5f546001600160a01b0316610143565b6100be6101ca3660046115de565b6106c2565b6101e26101dd36600461157f565b610aff565b6040516100c89190611742565b6101076101fd366004611751565b610c1d565b5f8281526003602090815260408083208151610120810190925280546001600160a01b03811683528493830190600160a01b900460ff16600481111561024a5761024a61163e565b600481111561025b5761025b61163e565b81528154600160a81b810460ff1615156020830152600160b01b90046001600160401b0316604082015260018201546001600160801b038082166060840152600160801b9182900481166080840152600284015480821660a085015291909104811660c083015260039092015490911660e09091015280519091506001600160a01b03166102ec575f91505061030d565b6102f98160200151611077565b80610309575061030981846110ae565b9150505b92915050565b61031b611116565b5f8181526003602090815260408083208151610120810190925280546001600160a01b03811683529192909190830190600160a01b900460ff1660048111156103665761036661163e565b60048111156103775761037761163e565b81528154600160a81b810460ff1615156020830152600160b01b90046001600160401b0316604082015260018201546001600160801b038082166060840152600160801b9182900481166080840152600284015480821660a085015291909104811660c083015260039092015490911660e090910152805190915082906001600160a01b03166104265760405163206ef55960e11b815260040161041d91815260200190565b60405180910390fd5b50805133906001600160a01b0381168214610467576040516311c0ae4560e21b81526001600160a01b0392831660048201529116602482015260440161041d565b50505f7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03166352566e936040518163ffffffff1660e01b8152600401606060405180830381865afa1580156104c6573d5f5f3e3d5ffd5b505050506040513d601f19601f820116820180604052508101906104ea91906117c9565b509150505f8183606001516001600160401b03166105089190611814565b90508042101581906105305760405163a9e6787760e01b815260040161041d91815260200190565b505f848152600360208190526040822080546001600160f01b031916815560018101839055600281018390550180546001600160801b03191690556101008401516001600160801b03166105838561114d565b61058d9190611814565b90508060025f8282546105a09190611827565b90915550506040805160208082525f90820152339187917f9e7f7245fec8cd99826dd2023848acf23bb5eca944f437d40a2b9d7f3f30944c910160405180910390a38351610619906001600160a01b037f000000000000000000000000000000000000000000000000000000000000000016908361117a565b505050506106256111af565b50565b5f5433906001600160a01b0316811461065e5760405162d1953b60e31b81526001600160a01b038216600482015260240161041d565b816001600160a01b03163b5f03610693576040516361798f2f60e11b81526001600160a01b038316600482015260240161041d565b61069c826111d9565b5050565b5f8054600160a01b900460ff166106b657505f90565b50638fb3603760e01b90565b5f6106cb611116565b5f5f7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03166352566e936040518163ffffffff1660e01b8152600401606060405180830381865afa158015610729573d5f5f3e3d5ffd5b505050506040513d601f19601f8201168201806040525081019061074d91906117c9565b92505091505f61075c8b61122c565b90508080156107685750815b1561078657604051630a9105a360e31b815260040160405180910390fd5b8483808210156107b257604051634dac79c560e01b81526004810192909252602482015260440161041d565b5050881515806107c157508715155b6107de57604051631630779760e01b815260040160405180910390fd5b6107e78b611077565b156108155786801561080f5760405163d4a8369b60e01b815260040161041d91815260200190565b50610858565b86806108375760405163d4a8369b60e01b815260040161041d91815260200190565b50885f0361085857604051631630779760e01b815260040160405180910390fd5b60018054905f6108678361183a565b919050559350604051806101200160405280336001600160a01b031681526020018c600481111561089a5761089a61163e565b81526020018b15158152602001426001600160401b031681526020016108bf8b61124e565b6001600160801b031681526020016108d68a61124e565b6001600160801b031681526020016108ed8961124e565b6001600160801b031681526020016109048861124e565b6001600160801b0316815260200161091b8761124e565b6001600160801b031690525f858152600360209081526040909120825181546001600160a01b039091166001600160a01b031982168117835592840151919283916001600160a81b03191617600160a01b83600481111561097e5761097e61163e565b021790555060408201518154606084015168ffffffffffffffffff60a81b19909116600160a81b9215159290920267ffffffffffffffff60b01b191691909117600160b01b6001600160401b0390921691909102178155608082015160a08301516001600160801b03918216600160801b918316820217600184015560c084015160e085015190831690831690910217600283015561010090920151600390910180546001600160801b031916919092161790555f8582610a3f575f610a41565b895b610a4b9190611814565b90508060025f828254610a5e9190611814565b92505081905550336001600160a01b0316857fd3a1164146eb83c011c8ac35f6d48b013553edaf9583eebd63593da17c9fcf148e8e8e8e8e8e8e604051610aab9796959493929190611852565b60405180910390a3610ae86001600160a01b037f000000000000000000000000000000000000000000000000000000000000000016333084611285565b50505050610af46111af565b979650505050505050565b60408051610120810182525f80825260208201819052918101829052606081018290526080810182905260a0810182905260c0810182905260e081018290526101008101919091525f828152600360209081526040918290208251610120810190935280546001600160a01b03811684529091830190600160a01b900460ff166004811115610b9057610b9061163e565b6004811115610ba157610ba161163e565b81528154600160a81b810460ff1615156020830152600160b01b90046001600160401b0316604082015260018201546001600160801b038082166060840152600160801b9182900481166080840152600284015480821660a085015291909104811660c083015260039092015490911660e09091015292915050565b610c25611116565b610c30335f366112c1565b5f8381526003602090815260408083208151610120810190925280546001600160a01b03811683529192909190830190600160a01b900460ff166004811115610c7b57610c7b61163e565b6004811115610c8c57610c8c61163e565b81528154600160a81b810460ff1615156020830152600160b01b90046001600160401b0316604082015260018201546001600160801b038082166060840152600160801b9182900481166080840152600284015480821660a085015291909104811660c083015260039092015490911660e090910152805190915084906001600160a01b0316610d325760405163206ef55960e11b815260040161041d91815260200190565b505f5f7f00000000000000000000000000000000000000000000000000000000000000006001600160a01b0316634bb28349868686606001516040518463ffffffff1660e01b8152600401610d89939291906118b8565b60408051808303815f875af1158015610da4573d5f5f3e3d5ffd5b505050506040513d601f19601f82011682018060405250810190610dc891906119c6565b91509150610dd98360200151611077565b610e2057610de783836110ae565b60c08401518391610e1d576040516306d14dc960e41b815260048101929092526001600160801b0316602482015260440161041d565b50505b5f868152600360208190526040822080546001600160f01b031916815560018101839055600281018390550180546001600160801b0319169055610e638461114d565b90508361010001516001600160801b031681610e7f9190611814565b60025f828254610e8f9190611827565b90915550506040516308d9243d60e21b81526001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000169063236490f490610ee290879087906004016119e8565b5f604051808303815f87803b158015610ef9575f5ffd5b505af1925050508015610f0a575060015b610fe3573d808015610f37576040519150601f19603f3d011682016040523d82523d5f602084013e610f3c565b606091505b5080515f03610f5e576040516350e6719d60e11b815260040160405180910390fd5b336001600160a01b0316887f9e7f7245fec8cd99826dd2023848acf23bb5eca944f437d40a2b9d7f3f30944c83604051610f989190611a05565b60405180910390a38115610fdd578451610fdd906001600160a01b037f000000000000000000000000000000000000000000000000000000000000000016908461117a565b50611021565b6040805184815260208101849052339189917f79e7fef5cd17ce2c61fe594632f498fbf07d1bf082540b02861ad2a3afb745e0910160405180910390a35b610100840151611066906001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000169033906001600160801b031661117a565b505050506110726111af565b505050565b5f8082600481111561108b5761108b61163e565b148061030d575060015b8260048111156110a7576110a761163e565b1492915050565b60c08201515f906001600160801b03166003846020015160048111156110d6576110d661163e565b036110fa5783604001516110ed57808311156110f2565b808310155b91505061030d565b836040015161110c5780831015610309565b9091111592915050565b61111e6113b7565b61114b60017f9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f005b906113f7565b565b5f61115b826020015161122c565b611165575f61116b565b8160a001515b6001600160801b031692915050565b61118783838360016113fe565b61107257604051635274afe760e01b81526001600160a01b038416600482015260240161041d565b61114b5f7f9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00611145565b5f80546001600160a01b0319166001600160a01b0383169081179091556040519081527f2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad9060200160405180910390a150565b5f808260048111156112405761124061163e565b148061030d57506002611095565b5f6001600160801b03821115611281576040516306dfcc6560e41b8152608060048201526024810183905260440161041d565b5090565b611293848484846001611460565b6112bb57604051635274afe760e01b81526001600160a01b038516600482015260240161041d565b50505050565b5f5f6112f46112d75f546001600160a01b031690565b86306112e660045f898b611a3a565b6112ef91611a61565b6114cd565b91509150816113b05763ffffffff81161561138d575f805460ff60a01b198116600160a01b17909155604051634a63ebf760e11b81526001600160a01b03909116906394c7d7ee9061134e90889088908890600401611a99565b5f604051808303815f87803b158015611365575f5ffd5b505af1158015611377573d5f5f3e3d5ffd5b50505f805460ff60a01b19169055506113b09050565b60405162d1953b60e31b81526001600160a01b038616600482015260240161041d565b5050505050565b7f9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f005c1561114b57604051633ee5aeb560e01b815260040160405180910390fd5b80825d5050565b60405163a9059cbb60e01b5f8181526001600160a01b038616600452602485905291602083604481808b5af1925060015f51148316611454578383151615611448573d5f823e3d81fd5b5f873b113d1516831692505b60405250949350505050565b6040516323b872dd60e01b5f8181526001600160a01b038781166004528616602452604485905291602083606481808c5af1925060015f511483166114bc5783831516156114b0573d5f823e3d81fd5b5f883b113d1516831692505b604052505f60605295945050505050565b6040516001600160a01b038085166024830152831660448201526001600160e01b0319821660648201525f908190819060840160408051601f19818403018152918152602080830180516001600160e01b031663b700961360e01b1781525f808052918290528351939450919290918a5afa15611555575f516020805191945081901c150291505b5094509492505050565b5f5f60408385031215611570575f5ffd5b50508035926020909101359150565b5f6020828403121561158f575f5ffd5b5035919050565b80356001600160a01b03811681146115ac575f5ffd5b919050565b5f602082840312156115c1575f5ffd5b6115ca82611596565b9392505050565b8015158114610625575f5ffd5b5f5f5f5f5f5f5f60e0888a0312156115f4575f5ffd5b873560058110611602575f5ffd5b96506020880135611612816115d1565b96999698505050506040850135946060810135946080820135945060a0820135935060c0909101359150565b634e487b7160e01b5f52602160045260245ffd5b6005811061166e57634e487b7160e01b5f52602160045260245ffd5b9052565b80516001600160a01b031682526020808201519061169290840182611652565b5060408101511515604083015260608101516116b960608401826001600160401b03169052565b5060808101516116d460808401826001600160801b03169052565b5060a08101516116ef60a08401826001600160801b03169052565b5060c081015161170a60c08401826001600160801b03169052565b5060e081015161172560e08401826001600160801b03169052565b506101008101516110726101008401826001600160801b03169052565b610120810161030d8284611672565b5f5f5f60408486031215611763575f5ffd5b8335925060208401356001600160401b0381111561177f575f5ffd5b8401601f8101861361178f575f5ffd5b80356001600160401b038111156117a4575f5ffd5b8660208260051b84010111156117b8575f5ffd5b939660209190910195509293505050565b5f5f5f606084860312156117db575f5ffd5b83516020850151604086015191945092506117f5816115d1565b809150509250925092565b634e487b7160e01b5f52601160045260245ffd5b8082018082111561030d5761030d611800565b8181038181111561030d5761030d611800565b5f6001820161184b5761184b611800565b5060010190565b60e08101611860828a611652565b961515602082015260408101959095526060850193909352608084019190915260a083015260c090910152919050565b81835281816020850137505f828201602090810191909152601f909101601f19169091010190565b604080825281018390525f6060600585901b830181019083018683607e1936839003015b888210156119a957868503605f1901845282358181126118fa575f5ffd5b8a016001600160a01b0361190d82611596565b1686526020818101359087015260408101356001600160401b038116808214611934575f5ffd5b604088015250606081013536829003601e19018112611951575f5ffd5b016020810190356001600160401b0381111561196b575f5ffd5b803603821315611979575f5ffd5b6080606088015261198e608088018284611890565b965050506020830192506020840193506001820191506118dc565b5050506001600160401b0385166020850152509050949350505050565b5f5f604083850312156119d7575f5ffd5b505080516020909101519092909150565b61014081016119f78285611672565b826101208301529392505050565b602081525f82518060208401528060208501604085015e5f604082850101526040601f19601f83011684010191505092915050565b5f5f85851115611a48575f5ffd5b83861115611a54575f5ffd5b5050820193919092039150565b80356001600160e01b03198116906004841015611a92576001600160e01b0319600485900360031b81901b82161691505b5092915050565b6001600160a01b03841681526040602082018190525f90611abd9083018486611890565b9594505050505056",
}

// PerpsMarketABI is the input ABI used to generate the binding from.
// Deprecated: Use PerpsMarketMetaData.ABI instead.
var PerpsMarketABI = PerpsMarketMetaData.ABI

// PerpsMarketBin is the compiled bytecode used for deploying new contracts.
// Deprecated: Use PerpsMarketMetaData.Bin instead.
var PerpsMarketBin = PerpsMarketMetaData.Bin

// DeployPerpsMarket deploys a new Ethereum contract, binding an instance of PerpsMarket to it.
func DeployPerpsMarket(auth *bind.TransactOpts, backend bind.ContractBackend, authority_ common.Address, collateral_ common.Address, oracle_ common.Address, marketId_ [32]byte, params_ IPerpsMarketRiskParams, vaultName string, vaultSymbol string) (common.Address, *types.Transaction, *PerpsMarket, error) {
	parsed, err := PerpsMarketMetaData.GetAbi()
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	if parsed == nil {
		return common.Address{}, nil, nil, errors.New("GetABI returned nil")
	}

	address, tx, contract, err := bind.DeployContract(auth, *parsed, common.FromHex(PerpsMarketBin), backend, authority_, collateral_, oracle_, marketId_, params_, vaultName, vaultSymbol)
	if err != nil {
		return common.Address{}, nil, nil, err
	}
	return address, tx, &PerpsMarket{PerpsMarketCaller: PerpsMarketCaller{contract: contract}, PerpsMarketTransactor: PerpsMarketTransactor{contract: contract}, PerpsMarketFilterer: PerpsMarketFilterer{contract: contract}}, nil
}

// PerpsMarket is an auto generated Go binding around an Ethereum contract.
type PerpsMarket struct {
	PerpsMarketCaller     // Read-only binding to the contract
	PerpsMarketTransactor // Write-only binding to the contract
	PerpsMarketFilterer   // Log filterer for contract events
}

// PerpsMarketCaller is an auto generated read-only Go binding around an Ethereum contract.
type PerpsMarketCaller struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// PerpsMarketTransactor is an auto generated write-only Go binding around an Ethereum contract.
type PerpsMarketTransactor struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// PerpsMarketFilterer is an auto generated log filtering Go binding around an Ethereum contract events.
type PerpsMarketFilterer struct {
	contract *bind.BoundContract // Generic contract wrapper for the low level calls
}

// PerpsMarketSession is an auto generated Go binding around an Ethereum contract,
// with pre-set call and transact options.
type PerpsMarketSession struct {
	Contract     *PerpsMarket      // Generic contract binding to set the session for
	CallOpts     bind.CallOpts     // Call options to use throughout this session
	TransactOpts bind.TransactOpts // Transaction auth options to use throughout this session
}

// PerpsMarketCallerSession is an auto generated read-only Go binding around an Ethereum contract,
// with pre-set call options.
type PerpsMarketCallerSession struct {
	Contract *PerpsMarketCaller // Generic contract caller binding to set the session for
	CallOpts bind.CallOpts      // Call options to use throughout this session
}

// PerpsMarketTransactorSession is an auto generated write-only Go binding around an Ethereum contract,
// with pre-set transact options.
type PerpsMarketTransactorSession struct {
	Contract     *PerpsMarketTransactor // Generic contract transactor binding to set the session for
	TransactOpts bind.TransactOpts      // Transaction auth options to use throughout this session
}

// PerpsMarketRaw is an auto generated low-level Go binding around an Ethereum contract.
type PerpsMarketRaw struct {
	Contract *PerpsMarket // Generic contract binding to access the raw methods on
}

// PerpsMarketCallerRaw is an auto generated low-level read-only Go binding around an Ethereum contract.
type PerpsMarketCallerRaw struct {
	Contract *PerpsMarketCaller // Generic read-only contract binding to access the raw methods on
}

// PerpsMarketTransactorRaw is an auto generated low-level write-only Go binding around an Ethereum contract.
type PerpsMarketTransactorRaw struct {
	Contract *PerpsMarketTransactor // Generic write-only contract binding to access the raw methods on
}

// NewPerpsMarket creates a new instance of PerpsMarket, bound to a specific deployed contract.
func NewPerpsMarket(address common.Address, backend bind.ContractBackend) (*PerpsMarket, error) {
	contract, err := bindPerpsMarket(address, backend, backend, backend)
	if err != nil {
		return nil, err
	}
	return &PerpsMarket{PerpsMarketCaller: PerpsMarketCaller{contract: contract}, PerpsMarketTransactor: PerpsMarketTransactor{contract: contract}, PerpsMarketFilterer: PerpsMarketFilterer{contract: contract}}, nil
}

// NewPerpsMarketCaller creates a new read-only instance of PerpsMarket, bound to a specific deployed contract.
func NewPerpsMarketCaller(address common.Address, caller bind.ContractCaller) (*PerpsMarketCaller, error) {
	contract, err := bindPerpsMarket(address, caller, nil, nil)
	if err != nil {
		return nil, err
	}
	return &PerpsMarketCaller{contract: contract}, nil
}

// NewPerpsMarketTransactor creates a new write-only instance of PerpsMarket, bound to a specific deployed contract.
func NewPerpsMarketTransactor(address common.Address, transactor bind.ContractTransactor) (*PerpsMarketTransactor, error) {
	contract, err := bindPerpsMarket(address, nil, transactor, nil)
	if err != nil {
		return nil, err
	}
	return &PerpsMarketTransactor{contract: contract}, nil
}

// NewPerpsMarketFilterer creates a new log filterer instance of PerpsMarket, bound to a specific deployed contract.
func NewPerpsMarketFilterer(address common.Address, filterer bind.ContractFilterer) (*PerpsMarketFilterer, error) {
	contract, err := bindPerpsMarket(address, nil, nil, filterer)
	if err != nil {
		return nil, err
	}
	return &PerpsMarketFilterer{contract: contract}, nil
}

// bindPerpsMarket binds a generic wrapper to an already deployed contract.
func bindPerpsMarket(address common.Address, caller bind.ContractCaller, transactor bind.ContractTransactor, filterer bind.ContractFilterer) (*bind.BoundContract, error) {
	parsed, err := PerpsMarketMetaData.GetAbi()
	if err != nil {
		return nil, err
	}
	return bind.NewBoundContract(address, *parsed, caller, transactor, filterer), nil
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_PerpsMarket *PerpsMarketRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _PerpsMarket.Contract.PerpsMarketCaller.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_PerpsMarket *PerpsMarketRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _PerpsMarket.Contract.PerpsMarketTransactor.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_PerpsMarket *PerpsMarketRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _PerpsMarket.Contract.PerpsMarketTransactor.contract.Transact(opts, method, params...)
}

// Call invokes the (constant) contract method with params as input values and
// sets the output to result. The result type might be a single field for simple
// returns, a slice of interfaces for anonymous returns and a struct for named
// returns.
func (_PerpsMarket *PerpsMarketCallerRaw) Call(opts *bind.CallOpts, result *[]interface{}, method string, params ...interface{}) error {
	return _PerpsMarket.Contract.contract.Call(opts, result, method, params...)
}

// Transfer initiates a plain transaction to move funds to the contract, calling
// its default method if one is available.
func (_PerpsMarket *PerpsMarketTransactorRaw) Transfer(opts *bind.TransactOpts) (*types.Transaction, error) {
	return _PerpsMarket.Contract.contract.Transfer(opts)
}

// Transact invokes the (paid) contract method with params as input values.
func (_PerpsMarket *PerpsMarketTransactorRaw) Transact(opts *bind.TransactOpts, method string, params ...interface{}) (*types.Transaction, error) {
	return _PerpsMarket.Contract.contract.Transact(opts, method, params...)
}

// IMPACTPOOLDISTRIBUTIONPERIOD is a free data retrieval call binding the contract method 0x5e1d515c.
//
// Solidity: function IMPACT_POOL_DISTRIBUTION_PERIOD() view returns(uint256)
func (_PerpsMarket *PerpsMarketCaller) IMPACTPOOLDISTRIBUTIONPERIOD(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "IMPACT_POOL_DISTRIBUTION_PERIOD")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// IMPACTPOOLDISTRIBUTIONPERIOD is a free data retrieval call binding the contract method 0x5e1d515c.
//
// Solidity: function IMPACT_POOL_DISTRIBUTION_PERIOD() view returns(uint256)
func (_PerpsMarket *PerpsMarketSession) IMPACTPOOLDISTRIBUTIONPERIOD() (*big.Int, error) {
	return _PerpsMarket.Contract.IMPACTPOOLDISTRIBUTIONPERIOD(&_PerpsMarket.CallOpts)
}

// IMPACTPOOLDISTRIBUTIONPERIOD is a free data retrieval call binding the contract method 0x5e1d515c.
//
// Solidity: function IMPACT_POOL_DISTRIBUTION_PERIOD() view returns(uint256)
func (_PerpsMarket *PerpsMarketCallerSession) IMPACTPOOLDISTRIBUTIONPERIOD() (*big.Int, error) {
	return _PerpsMarket.Contract.IMPACTPOOLDISTRIBUTIONPERIOD(&_PerpsMarket.CallOpts)
}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_PerpsMarket *PerpsMarketCaller) Authority(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "authority")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_PerpsMarket *PerpsMarketSession) Authority() (common.Address, error) {
	return _PerpsMarket.Contract.Authority(&_PerpsMarket.CallOpts)
}

// Authority is a free data retrieval call binding the contract method 0xbf7e214f.
//
// Solidity: function authority() view returns(address)
func (_PerpsMarket *PerpsMarketCallerSession) Authority() (common.Address, error) {
	return _PerpsMarket.Contract.Authority(&_PerpsMarket.CallOpts)
}

// CollateralToken is a free data retrieval call binding the contract method 0xb2016bd4.
//
// Solidity: function collateralToken() view returns(address)
func (_PerpsMarket *PerpsMarketCaller) CollateralToken(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "collateralToken")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// CollateralToken is a free data retrieval call binding the contract method 0xb2016bd4.
//
// Solidity: function collateralToken() view returns(address)
func (_PerpsMarket *PerpsMarketSession) CollateralToken() (common.Address, error) {
	return _PerpsMarket.Contract.CollateralToken(&_PerpsMarket.CallOpts)
}

// CollateralToken is a free data retrieval call binding the contract method 0xb2016bd4.
//
// Solidity: function collateralToken() view returns(address)
func (_PerpsMarket *PerpsMarketCallerSession) CollateralToken() (common.Address, error) {
	return _PerpsMarket.Contract.CollateralToken(&_PerpsMarket.CallOpts)
}

// FundingIndex is a free data retrieval call binding the contract method 0x99be9632.
//
// Solidity: function fundingIndex() view returns(int256)
func (_PerpsMarket *PerpsMarketCaller) FundingIndex(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "fundingIndex")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// FundingIndex is a free data retrieval call binding the contract method 0x99be9632.
//
// Solidity: function fundingIndex() view returns(int256)
func (_PerpsMarket *PerpsMarketSession) FundingIndex() (*big.Int, error) {
	return _PerpsMarket.Contract.FundingIndex(&_PerpsMarket.CallOpts)
}

// FundingIndex is a free data retrieval call binding the contract method 0x99be9632.
//
// Solidity: function fundingIndex() view returns(int256)
func (_PerpsMarket *PerpsMarketCallerSession) FundingIndex() (*big.Int, error) {
	return _PerpsMarket.Contract.FundingIndex(&_PerpsMarket.CallOpts)
}

// FundingRate is a free data retrieval call binding the contract method 0x41d3c84c.
//
// Solidity: function fundingRate() view returns(int256)
func (_PerpsMarket *PerpsMarketCaller) FundingRate(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "fundingRate")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// FundingRate is a free data retrieval call binding the contract method 0x41d3c84c.
//
// Solidity: function fundingRate() view returns(int256)
func (_PerpsMarket *PerpsMarketSession) FundingRate() (*big.Int, error) {
	return _PerpsMarket.Contract.FundingRate(&_PerpsMarket.CallOpts)
}

// FundingRate is a free data retrieval call binding the contract method 0x41d3c84c.
//
// Solidity: function fundingRate() view returns(int256)
func (_PerpsMarket *PerpsMarketCallerSession) FundingRate() (*big.Int, error) {
	return _PerpsMarket.Contract.FundingRate(&_PerpsMarket.CallOpts)
}

// GetPosition is a free data retrieval call binding the contract method 0xc968b70e.
//
// Solidity: function getPosition(address account, bool isLong) view returns((uint128,uint128,uint128,uint64,uint128,int128))
func (_PerpsMarket *PerpsMarketCaller) GetPosition(opts *bind.CallOpts, account common.Address, isLong bool) (IPerpsMarketPosition, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "getPosition", account, isLong)

	if err != nil {
		return *new(IPerpsMarketPosition), err
	}

	out0 := *abi.ConvertType(out[0], new(IPerpsMarketPosition)).(*IPerpsMarketPosition)

	return out0, err

}

// GetPosition is a free data retrieval call binding the contract method 0xc968b70e.
//
// Solidity: function getPosition(address account, bool isLong) view returns((uint128,uint128,uint128,uint64,uint128,int128))
func (_PerpsMarket *PerpsMarketSession) GetPosition(account common.Address, isLong bool) (IPerpsMarketPosition, error) {
	return _PerpsMarket.Contract.GetPosition(&_PerpsMarket.CallOpts, account, isLong)
}

// GetPosition is a free data retrieval call binding the contract method 0xc968b70e.
//
// Solidity: function getPosition(address account, bool isLong) view returns((uint128,uint128,uint128,uint64,uint128,int128))
func (_PerpsMarket *PerpsMarketCallerSession) GetPosition(account common.Address, isLong bool) (IPerpsMarketPosition, error) {
	return _PerpsMarket.Contract.GetPosition(&_PerpsMarket.CallOpts, account, isLong)
}

// GetRiskParams is a free data retrieval call binding the contract method 0x69794795.
//
// Solidity: function getRiskParams() view returns((uint128,uint128,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16,uint32,uint128,uint128,uint128,uint64,uint64,uint64,uint128,uint128))
func (_PerpsMarket *PerpsMarketCaller) GetRiskParams(opts *bind.CallOpts) (IPerpsMarketRiskParams, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "getRiskParams")

	if err != nil {
		return *new(IPerpsMarketRiskParams), err
	}

	out0 := *abi.ConvertType(out[0], new(IPerpsMarketRiskParams)).(*IPerpsMarketRiskParams)

	return out0, err

}

// GetRiskParams is a free data retrieval call binding the contract method 0x69794795.
//
// Solidity: function getRiskParams() view returns((uint128,uint128,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16,uint32,uint128,uint128,uint128,uint64,uint64,uint64,uint128,uint128))
func (_PerpsMarket *PerpsMarketSession) GetRiskParams() (IPerpsMarketRiskParams, error) {
	return _PerpsMarket.Contract.GetRiskParams(&_PerpsMarket.CallOpts)
}

// GetRiskParams is a free data retrieval call binding the contract method 0x69794795.
//
// Solidity: function getRiskParams() view returns((uint128,uint128,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16,uint32,uint128,uint128,uint128,uint64,uint64,uint64,uint128,uint128))
func (_PerpsMarket *PerpsMarketCallerSession) GetRiskParams() (IPerpsMarketRiskParams, error) {
	return _PerpsMarket.Contract.GetRiskParams(&_PerpsMarket.CallOpts)
}

// GetSide is a free data retrieval call binding the contract method 0x80f85260.
//
// Solidity: function getSide(bool isLong) view returns((uint256,uint256,uint256,uint256,int256))
func (_PerpsMarket *PerpsMarketCaller) GetSide(opts *bind.CallOpts, isLong bool) (IPerpsMarketSideState, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "getSide", isLong)

	if err != nil {
		return *new(IPerpsMarketSideState), err
	}

	out0 := *abi.ConvertType(out[0], new(IPerpsMarketSideState)).(*IPerpsMarketSideState)

	return out0, err

}

// GetSide is a free data retrieval call binding the contract method 0x80f85260.
//
// Solidity: function getSide(bool isLong) view returns((uint256,uint256,uint256,uint256,int256))
func (_PerpsMarket *PerpsMarketSession) GetSide(isLong bool) (IPerpsMarketSideState, error) {
	return _PerpsMarket.Contract.GetSide(&_PerpsMarket.CallOpts, isLong)
}

// GetSide is a free data retrieval call binding the contract method 0x80f85260.
//
// Solidity: function getSide(bool isLong) view returns((uint256,uint256,uint256,uint256,int256))
func (_PerpsMarket *PerpsMarketCallerSession) GetSide(isLong bool) (IPerpsMarketSideState, error) {
	return _PerpsMarket.Contract.GetSide(&_PerpsMarket.CallOpts, isLong)
}

// GetStats is a free data retrieval call binding the contract method 0xc59d4847.
//
// Solidity: function getStats() view returns((uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128))
func (_PerpsMarket *PerpsMarketCaller) GetStats(opts *bind.CallOpts) (IPerpsMarketMarketStats, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "getStats")

	if err != nil {
		return *new(IPerpsMarketMarketStats), err
	}

	out0 := *abi.ConvertType(out[0], new(IPerpsMarketMarketStats)).(*IPerpsMarketMarketStats)

	return out0, err

}

// GetStats is a free data retrieval call binding the contract method 0xc59d4847.
//
// Solidity: function getStats() view returns((uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128))
func (_PerpsMarket *PerpsMarketSession) GetStats() (IPerpsMarketMarketStats, error) {
	return _PerpsMarket.Contract.GetStats(&_PerpsMarket.CallOpts)
}

// GetStats is a free data retrieval call binding the contract method 0xc59d4847.
//
// Solidity: function getStats() view returns((uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128))
func (_PerpsMarket *PerpsMarketCallerSession) GetStats() (IPerpsMarketMarketStats, error) {
	return _PerpsMarket.Contract.GetStats(&_PerpsMarket.CallOpts)
}

// ImpactPoolAmount is a free data retrieval call binding the contract method 0xef165dd9.
//
// Solidity: function impactPoolAmount() view returns(uint256)
func (_PerpsMarket *PerpsMarketCaller) ImpactPoolAmount(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "impactPoolAmount")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// ImpactPoolAmount is a free data retrieval call binding the contract method 0xef165dd9.
//
// Solidity: function impactPoolAmount() view returns(uint256)
func (_PerpsMarket *PerpsMarketSession) ImpactPoolAmount() (*big.Int, error) {
	return _PerpsMarket.Contract.ImpactPoolAmount(&_PerpsMarket.CallOpts)
}

// ImpactPoolAmount is a free data retrieval call binding the contract method 0xef165dd9.
//
// Solidity: function impactPoolAmount() view returns(uint256)
func (_PerpsMarket *PerpsMarketCallerSession) ImpactPoolAmount() (*big.Int, error) {
	return _PerpsMarket.Contract.ImpactPoolAmount(&_PerpsMarket.CallOpts)
}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_PerpsMarket *PerpsMarketCaller) IsConsumingScheduledOp(opts *bind.CallOpts) ([4]byte, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "isConsumingScheduledOp")

	if err != nil {
		return *new([4]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([4]byte)).(*[4]byte)

	return out0, err

}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_PerpsMarket *PerpsMarketSession) IsConsumingScheduledOp() ([4]byte, error) {
	return _PerpsMarket.Contract.IsConsumingScheduledOp(&_PerpsMarket.CallOpts)
}

// IsConsumingScheduledOp is a free data retrieval call binding the contract method 0x8fb36037.
//
// Solidity: function isConsumingScheduledOp() view returns(bytes4)
func (_PerpsMarket *PerpsMarketCallerSession) IsConsumingScheduledOp() ([4]byte, error) {
	return _PerpsMarket.Contract.IsConsumingScheduledOp(&_PerpsMarket.CallOpts)
}

// LastAccrualAt is a free data retrieval call binding the contract method 0x3131fd71.
//
// Solidity: function lastAccrualAt() view returns(uint64)
func (_PerpsMarket *PerpsMarketCaller) LastAccrualAt(opts *bind.CallOpts) (uint64, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "lastAccrualAt")

	if err != nil {
		return *new(uint64), err
	}

	out0 := *abi.ConvertType(out[0], new(uint64)).(*uint64)

	return out0, err

}

// LastAccrualAt is a free data retrieval call binding the contract method 0x3131fd71.
//
// Solidity: function lastAccrualAt() view returns(uint64)
func (_PerpsMarket *PerpsMarketSession) LastAccrualAt() (uint64, error) {
	return _PerpsMarket.Contract.LastAccrualAt(&_PerpsMarket.CallOpts)
}

// LastAccrualAt is a free data retrieval call binding the contract method 0x3131fd71.
//
// Solidity: function lastAccrualAt() view returns(uint64)
func (_PerpsMarket *PerpsMarketCallerSession) LastAccrualAt() (uint64, error) {
	return _PerpsMarket.Contract.LastAccrualAt(&_PerpsMarket.CallOpts)
}

// LastPrice is a free data retrieval call binding the contract method 0x053f14da.
//
// Solidity: function lastPrice() view returns(uint256)
func (_PerpsMarket *PerpsMarketCaller) LastPrice(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "lastPrice")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// LastPrice is a free data retrieval call binding the contract method 0x053f14da.
//
// Solidity: function lastPrice() view returns(uint256)
func (_PerpsMarket *PerpsMarketSession) LastPrice() (*big.Int, error) {
	return _PerpsMarket.Contract.LastPrice(&_PerpsMarket.CallOpts)
}

// LastPrice is a free data retrieval call binding the contract method 0x053f14da.
//
// Solidity: function lastPrice() view returns(uint256)
func (_PerpsMarket *PerpsMarketCallerSession) LastPrice() (*big.Int, error) {
	return _PerpsMarket.Contract.LastPrice(&_PerpsMarket.CallOpts)
}

// LastPriceTimestamp is a free data retrieval call binding the contract method 0x7de93f93.
//
// Solidity: function lastPriceTimestamp() view returns(uint256)
func (_PerpsMarket *PerpsMarketCaller) LastPriceTimestamp(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "lastPriceTimestamp")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// LastPriceTimestamp is a free data retrieval call binding the contract method 0x7de93f93.
//
// Solidity: function lastPriceTimestamp() view returns(uint256)
func (_PerpsMarket *PerpsMarketSession) LastPriceTimestamp() (*big.Int, error) {
	return _PerpsMarket.Contract.LastPriceTimestamp(&_PerpsMarket.CallOpts)
}

// LastPriceTimestamp is a free data retrieval call binding the contract method 0x7de93f93.
//
// Solidity: function lastPriceTimestamp() view returns(uint256)
func (_PerpsMarket *PerpsMarketCallerSession) LastPriceTimestamp() (*big.Int, error) {
	return _PerpsMarket.Contract.LastPriceTimestamp(&_PerpsMarket.CallOpts)
}

// MarketId is a free data retrieval call binding the contract method 0x6ed71ede.
//
// Solidity: function marketId() view returns(bytes32)
func (_PerpsMarket *PerpsMarketCaller) MarketId(opts *bind.CallOpts) ([32]byte, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "marketId")

	if err != nil {
		return *new([32]byte), err
	}

	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)

	return out0, err

}

// MarketId is a free data retrieval call binding the contract method 0x6ed71ede.
//
// Solidity: function marketId() view returns(bytes32)
func (_PerpsMarket *PerpsMarketSession) MarketId() ([32]byte, error) {
	return _PerpsMarket.Contract.MarketId(&_PerpsMarket.CallOpts)
}

// MarketId is a free data retrieval call binding the contract method 0x6ed71ede.
//
// Solidity: function marketId() view returns(bytes32)
func (_PerpsMarket *PerpsMarketCallerSession) MarketId() ([32]byte, error) {
	return _PerpsMarket.Contract.MarketId(&_PerpsMarket.CallOpts)
}

// Oracle is a free data retrieval call binding the contract method 0x7dc0d1d0.
//
// Solidity: function oracle() view returns(address)
func (_PerpsMarket *PerpsMarketCaller) Oracle(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "oracle")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Oracle is a free data retrieval call binding the contract method 0x7dc0d1d0.
//
// Solidity: function oracle() view returns(address)
func (_PerpsMarket *PerpsMarketSession) Oracle() (common.Address, error) {
	return _PerpsMarket.Contract.Oracle(&_PerpsMarket.CallOpts)
}

// Oracle is a free data retrieval call binding the contract method 0x7dc0d1d0.
//
// Solidity: function oracle() view returns(address)
func (_PerpsMarket *PerpsMarketCallerSession) Oracle() (common.Address, error) {
	return _PerpsMarket.Contract.Oracle(&_PerpsMarket.CallOpts)
}

// OrderBook is a free data retrieval call binding the contract method 0x776af5ba.
//
// Solidity: function orderBook() view returns(address)
func (_PerpsMarket *PerpsMarketCaller) OrderBook(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "orderBook")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// OrderBook is a free data retrieval call binding the contract method 0x776af5ba.
//
// Solidity: function orderBook() view returns(address)
func (_PerpsMarket *PerpsMarketSession) OrderBook() (common.Address, error) {
	return _PerpsMarket.Contract.OrderBook(&_PerpsMarket.CallOpts)
}

// OrderBook is a free data retrieval call binding the contract method 0x776af5ba.
//
// Solidity: function orderBook() view returns(address)
func (_PerpsMarket *PerpsMarketCallerSession) OrderBook() (common.Address, error) {
	return _PerpsMarket.Contract.OrderBook(&_PerpsMarket.CallOpts)
}

// Paused is a free data retrieval call binding the contract method 0x5c975abb.
//
// Solidity: function paused() view returns(bool)
func (_PerpsMarket *PerpsMarketCaller) Paused(opts *bind.CallOpts) (bool, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "paused")

	if err != nil {
		return *new(bool), err
	}

	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)

	return out0, err

}

// Paused is a free data retrieval call binding the contract method 0x5c975abb.
//
// Solidity: function paused() view returns(bool)
func (_PerpsMarket *PerpsMarketSession) Paused() (bool, error) {
	return _PerpsMarket.Contract.Paused(&_PerpsMarket.CallOpts)
}

// Paused is a free data retrieval call binding the contract method 0x5c975abb.
//
// Solidity: function paused() view returns(bool)
func (_PerpsMarket *PerpsMarketCallerSession) Paused() (bool, error) {
	return _PerpsMarket.Contract.Paused(&_PerpsMarket.CallOpts)
}

// PnlToPoolFactor is a free data retrieval call binding the contract method 0xf2df39cb.
//
// Solidity: function pnlToPoolFactor(uint256 price) view returns(uint256 factor, uint256 positivePnl)
func (_PerpsMarket *PerpsMarketCaller) PnlToPoolFactor(opts *bind.CallOpts, price *big.Int) (struct {
	Factor      *big.Int
	PositivePnl *big.Int
}, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "pnlToPoolFactor", price)

	outstruct := new(struct {
		Factor      *big.Int
		PositivePnl *big.Int
	})
	if err != nil {
		return *outstruct, err
	}

	outstruct.Factor = *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)
	outstruct.PositivePnl = *abi.ConvertType(out[1], new(*big.Int)).(**big.Int)

	return *outstruct, err

}

// PnlToPoolFactor is a free data retrieval call binding the contract method 0xf2df39cb.
//
// Solidity: function pnlToPoolFactor(uint256 price) view returns(uint256 factor, uint256 positivePnl)
func (_PerpsMarket *PerpsMarketSession) PnlToPoolFactor(price *big.Int) (struct {
	Factor      *big.Int
	PositivePnl *big.Int
}, error) {
	return _PerpsMarket.Contract.PnlToPoolFactor(&_PerpsMarket.CallOpts, price)
}

// PnlToPoolFactor is a free data retrieval call binding the contract method 0xf2df39cb.
//
// Solidity: function pnlToPoolFactor(uint256 price) view returns(uint256 factor, uint256 positivePnl)
func (_PerpsMarket *PerpsMarketCallerSession) PnlToPoolFactor(price *big.Int) (struct {
	Factor      *big.Int
	PositivePnl *big.Int
}, error) {
	return _PerpsMarket.Contract.PnlToPoolFactor(&_PerpsMarket.CallOpts, price)
}

// PoolAmount is a free data retrieval call binding the contract method 0xa693600b.
//
// Solidity: function poolAmount() view returns(uint256)
func (_PerpsMarket *PerpsMarketCaller) PoolAmount(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "poolAmount")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// PoolAmount is a free data retrieval call binding the contract method 0xa693600b.
//
// Solidity: function poolAmount() view returns(uint256)
func (_PerpsMarket *PerpsMarketSession) PoolAmount() (*big.Int, error) {
	return _PerpsMarket.Contract.PoolAmount(&_PerpsMarket.CallOpts)
}

// PoolAmount is a free data retrieval call binding the contract method 0xa693600b.
//
// Solidity: function poolAmount() view returns(uint256)
func (_PerpsMarket *PerpsMarketCallerSession) PoolAmount() (*big.Int, error) {
	return _PerpsMarket.Contract.PoolAmount(&_PerpsMarket.CallOpts)
}

// PoolValue is a free data retrieval call binding the contract method 0xb8615071.
//
// Solidity: function poolValue() view returns(uint256)
func (_PerpsMarket *PerpsMarketCaller) PoolValue(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "poolValue")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// PoolValue is a free data retrieval call binding the contract method 0xb8615071.
//
// Solidity: function poolValue() view returns(uint256)
func (_PerpsMarket *PerpsMarketSession) PoolValue() (*big.Int, error) {
	return _PerpsMarket.Contract.PoolValue(&_PerpsMarket.CallOpts)
}

// PoolValue is a free data retrieval call binding the contract method 0xb8615071.
//
// Solidity: function poolValue() view returns(uint256)
func (_PerpsMarket *PerpsMarketCallerSession) PoolValue() (*big.Int, error) {
	return _PerpsMarket.Contract.PoolValue(&_PerpsMarket.CallOpts)
}

// PoolValueAt is a free data retrieval call binding the contract method 0xcaf17f01.
//
// Solidity: function poolValueAt(uint256 price) view returns(uint256)
func (_PerpsMarket *PerpsMarketCaller) PoolValueAt(opts *bind.CallOpts, price *big.Int) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "poolValueAt", price)

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// PoolValueAt is a free data retrieval call binding the contract method 0xcaf17f01.
//
// Solidity: function poolValueAt(uint256 price) view returns(uint256)
func (_PerpsMarket *PerpsMarketSession) PoolValueAt(price *big.Int) (*big.Int, error) {
	return _PerpsMarket.Contract.PoolValueAt(&_PerpsMarket.CallOpts, price)
}

// PoolValueAt is a free data retrieval call binding the contract method 0xcaf17f01.
//
// Solidity: function poolValueAt(uint256 price) view returns(uint256)
func (_PerpsMarket *PerpsMarketCallerSession) PoolValueAt(price *big.Int) (*big.Int, error) {
	return _PerpsMarket.Contract.PoolValueAt(&_PerpsMarket.CallOpts, price)
}

// PositionInfo is a free data retrieval call binding the contract method 0xba8c1d5b.
//
// Solidity: function positionInfo(address account, bool isLong, uint256 price) view returns((int256,uint256,int256,uint256,int256,uint256,bool) info)
func (_PerpsMarket *PerpsMarketCaller) PositionInfo(opts *bind.CallOpts, account common.Address, isLong bool, price *big.Int) (IPerpsMarketPositionInfo, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "positionInfo", account, isLong, price)

	if err != nil {
		return *new(IPerpsMarketPositionInfo), err
	}

	out0 := *abi.ConvertType(out[0], new(IPerpsMarketPositionInfo)).(*IPerpsMarketPositionInfo)

	return out0, err

}

// PositionInfo is a free data retrieval call binding the contract method 0xba8c1d5b.
//
// Solidity: function positionInfo(address account, bool isLong, uint256 price) view returns((int256,uint256,int256,uint256,int256,uint256,bool) info)
func (_PerpsMarket *PerpsMarketSession) PositionInfo(account common.Address, isLong bool, price *big.Int) (IPerpsMarketPositionInfo, error) {
	return _PerpsMarket.Contract.PositionInfo(&_PerpsMarket.CallOpts, account, isLong, price)
}

// PositionInfo is a free data retrieval call binding the contract method 0xba8c1d5b.
//
// Solidity: function positionInfo(address account, bool isLong, uint256 price) view returns((int256,uint256,int256,uint256,int256,uint256,bool) info)
func (_PerpsMarket *PerpsMarketCallerSession) PositionInfo(account common.Address, isLong bool, price *big.Int) (IPerpsMarketPositionInfo, error) {
	return _PerpsMarket.Contract.PositionInfo(&_PerpsMarket.CallOpts, account, isLong, price)
}

// RequestConfig is a free data retrieval call binding the contract method 0x52566e93.
//
// Solidity: function requestConfig() view returns(uint256 minExecutionFee, uint256 orderTimeout, bool isPaused)
func (_PerpsMarket *PerpsMarketCaller) RequestConfig(opts *bind.CallOpts) (struct {
	MinExecutionFee *big.Int
	OrderTimeout    *big.Int
	IsPaused        bool
}, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "requestConfig")

	outstruct := new(struct {
		MinExecutionFee *big.Int
		OrderTimeout    *big.Int
		IsPaused        bool
	})
	if err != nil {
		return *outstruct, err
	}

	outstruct.MinExecutionFee = *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)
	outstruct.OrderTimeout = *abi.ConvertType(out[1], new(*big.Int)).(**big.Int)
	outstruct.IsPaused = *abi.ConvertType(out[2], new(bool)).(*bool)

	return *outstruct, err

}

// RequestConfig is a free data retrieval call binding the contract method 0x52566e93.
//
// Solidity: function requestConfig() view returns(uint256 minExecutionFee, uint256 orderTimeout, bool isPaused)
func (_PerpsMarket *PerpsMarketSession) RequestConfig() (struct {
	MinExecutionFee *big.Int
	OrderTimeout    *big.Int
	IsPaused        bool
}, error) {
	return _PerpsMarket.Contract.RequestConfig(&_PerpsMarket.CallOpts)
}

// RequestConfig is a free data retrieval call binding the contract method 0x52566e93.
//
// Solidity: function requestConfig() view returns(uint256 minExecutionFee, uint256 orderTimeout, bool isPaused)
func (_PerpsMarket *PerpsMarketCallerSession) RequestConfig() (struct {
	MinExecutionFee *big.Int
	OrderTimeout    *big.Int
	IsPaused        bool
}, error) {
	return _PerpsMarket.Contract.RequestConfig(&_PerpsMarket.CallOpts)
}

// TotalCollateral is a free data retrieval call binding the contract method 0x4ac8eb5f.
//
// Solidity: function totalCollateral() view returns(uint256)
func (_PerpsMarket *PerpsMarketCaller) TotalCollateral(opts *bind.CallOpts) (*big.Int, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "totalCollateral")

	if err != nil {
		return *new(*big.Int), err
	}

	out0 := *abi.ConvertType(out[0], new(*big.Int)).(**big.Int)

	return out0, err

}

// TotalCollateral is a free data retrieval call binding the contract method 0x4ac8eb5f.
//
// Solidity: function totalCollateral() view returns(uint256)
func (_PerpsMarket *PerpsMarketSession) TotalCollateral() (*big.Int, error) {
	return _PerpsMarket.Contract.TotalCollateral(&_PerpsMarket.CallOpts)
}

// TotalCollateral is a free data retrieval call binding the contract method 0x4ac8eb5f.
//
// Solidity: function totalCollateral() view returns(uint256)
func (_PerpsMarket *PerpsMarketCallerSession) TotalCollateral() (*big.Int, error) {
	return _PerpsMarket.Contract.TotalCollateral(&_PerpsMarket.CallOpts)
}

// Vault is a free data retrieval call binding the contract method 0xfbfa77cf.
//
// Solidity: function vault() view returns(address)
func (_PerpsMarket *PerpsMarketCaller) Vault(opts *bind.CallOpts) (common.Address, error) {
	var out []interface{}
	err := _PerpsMarket.contract.Call(opts, &out, "vault")

	if err != nil {
		return *new(common.Address), err
	}

	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)

	return out0, err

}

// Vault is a free data retrieval call binding the contract method 0xfbfa77cf.
//
// Solidity: function vault() view returns(address)
func (_PerpsMarket *PerpsMarketSession) Vault() (common.Address, error) {
	return _PerpsMarket.Contract.Vault(&_PerpsMarket.CallOpts)
}

// Vault is a free data retrieval call binding the contract method 0xfbfa77cf.
//
// Solidity: function vault() view returns(address)
func (_PerpsMarket *PerpsMarketCallerSession) Vault() (common.Address, error) {
	return _PerpsMarket.Contract.Vault(&_PerpsMarket.CallOpts)
}

// AddLiquidity is a paid mutator transaction binding the contract method 0x51c6590a.
//
// Solidity: function addLiquidity(uint256 assets) returns()
func (_PerpsMarket *PerpsMarketTransactor) AddLiquidity(opts *bind.TransactOpts, assets *big.Int) (*types.Transaction, error) {
	return _PerpsMarket.contract.Transact(opts, "addLiquidity", assets)
}

// AddLiquidity is a paid mutator transaction binding the contract method 0x51c6590a.
//
// Solidity: function addLiquidity(uint256 assets) returns()
func (_PerpsMarket *PerpsMarketSession) AddLiquidity(assets *big.Int) (*types.Transaction, error) {
	return _PerpsMarket.Contract.AddLiquidity(&_PerpsMarket.TransactOpts, assets)
}

// AddLiquidity is a paid mutator transaction binding the contract method 0x51c6590a.
//
// Solidity: function addLiquidity(uint256 assets) returns()
func (_PerpsMarket *PerpsMarketTransactorSession) AddLiquidity(assets *big.Int) (*types.Transaction, error) {
	return _PerpsMarket.Contract.AddLiquidity(&_PerpsMarket.TransactOpts, assets)
}

// AutoDeleverage is a paid mutator transaction binding the contract method 0x5ab168e8.
//
// Solidity: function autoDeleverage(address account, bool isLong, (address,uint256,uint64,bytes)[] reports) returns()
func (_PerpsMarket *PerpsMarketTransactor) AutoDeleverage(opts *bind.TransactOpts, account common.Address, isLong bool, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _PerpsMarket.contract.Transact(opts, "autoDeleverage", account, isLong, reports)
}

// AutoDeleverage is a paid mutator transaction binding the contract method 0x5ab168e8.
//
// Solidity: function autoDeleverage(address account, bool isLong, (address,uint256,uint64,bytes)[] reports) returns()
func (_PerpsMarket *PerpsMarketSession) AutoDeleverage(account common.Address, isLong bool, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _PerpsMarket.Contract.AutoDeleverage(&_PerpsMarket.TransactOpts, account, isLong, reports)
}

// AutoDeleverage is a paid mutator transaction binding the contract method 0x5ab168e8.
//
// Solidity: function autoDeleverage(address account, bool isLong, (address,uint256,uint64,bytes)[] reports) returns()
func (_PerpsMarket *PerpsMarketTransactorSession) AutoDeleverage(account common.Address, isLong bool, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _PerpsMarket.Contract.AutoDeleverage(&_PerpsMarket.TransactOpts, account, isLong, reports)
}

// FillOrder is a paid mutator transaction binding the contract method 0x236490f4.
//
// Solidity: function fillOrder((address,uint8,bool,uint64,uint128,uint128,uint128,uint128,uint128) order, uint256 price) returns()
func (_PerpsMarket *PerpsMarketTransactor) FillOrder(opts *bind.TransactOpts, order IOrderBookOrder, price *big.Int) (*types.Transaction, error) {
	return _PerpsMarket.contract.Transact(opts, "fillOrder", order, price)
}

// FillOrder is a paid mutator transaction binding the contract method 0x236490f4.
//
// Solidity: function fillOrder((address,uint8,bool,uint64,uint128,uint128,uint128,uint128,uint128) order, uint256 price) returns()
func (_PerpsMarket *PerpsMarketSession) FillOrder(order IOrderBookOrder, price *big.Int) (*types.Transaction, error) {
	return _PerpsMarket.Contract.FillOrder(&_PerpsMarket.TransactOpts, order, price)
}

// FillOrder is a paid mutator transaction binding the contract method 0x236490f4.
//
// Solidity: function fillOrder((address,uint8,bool,uint64,uint128,uint128,uint128,uint128,uint128) order, uint256 price) returns()
func (_PerpsMarket *PerpsMarketTransactorSession) FillOrder(order IOrderBookOrder, price *big.Int) (*types.Transaction, error) {
	return _PerpsMarket.Contract.FillOrder(&_PerpsMarket.TransactOpts, order, price)
}

// Liquidate is a paid mutator transaction binding the contract method 0xd6bb4804.
//
// Solidity: function liquidate(address account, bool isLong, (address,uint256,uint64,bytes)[] reports) returns()
func (_PerpsMarket *PerpsMarketTransactor) Liquidate(opts *bind.TransactOpts, account common.Address, isLong bool, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _PerpsMarket.contract.Transact(opts, "liquidate", account, isLong, reports)
}

// Liquidate is a paid mutator transaction binding the contract method 0xd6bb4804.
//
// Solidity: function liquidate(address account, bool isLong, (address,uint256,uint64,bytes)[] reports) returns()
func (_PerpsMarket *PerpsMarketSession) Liquidate(account common.Address, isLong bool, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _PerpsMarket.Contract.Liquidate(&_PerpsMarket.TransactOpts, account, isLong, reports)
}

// Liquidate is a paid mutator transaction binding the contract method 0xd6bb4804.
//
// Solidity: function liquidate(address account, bool isLong, (address,uint256,uint64,bytes)[] reports) returns()
func (_PerpsMarket *PerpsMarketTransactorSession) Liquidate(account common.Address, isLong bool, reports []IOracleVerifierSignedPriceReport) (*types.Transaction, error) {
	return _PerpsMarket.Contract.Liquidate(&_PerpsMarket.TransactOpts, account, isLong, reports)
}

// RefreshPrice is a paid mutator transaction binding the contract method 0x4bb28349.
//
// Solidity: function refreshPrice((address,uint256,uint64,bytes)[] reports, uint256 notBefore) returns(uint256 price, uint256 oldestTimestamp)
func (_PerpsMarket *PerpsMarketTransactor) RefreshPrice(opts *bind.TransactOpts, reports []IOracleVerifierSignedPriceReport, notBefore *big.Int) (*types.Transaction, error) {
	return _PerpsMarket.contract.Transact(opts, "refreshPrice", reports, notBefore)
}

// RefreshPrice is a paid mutator transaction binding the contract method 0x4bb28349.
//
// Solidity: function refreshPrice((address,uint256,uint64,bytes)[] reports, uint256 notBefore) returns(uint256 price, uint256 oldestTimestamp)
func (_PerpsMarket *PerpsMarketSession) RefreshPrice(reports []IOracleVerifierSignedPriceReport, notBefore *big.Int) (*types.Transaction, error) {
	return _PerpsMarket.Contract.RefreshPrice(&_PerpsMarket.TransactOpts, reports, notBefore)
}

// RefreshPrice is a paid mutator transaction binding the contract method 0x4bb28349.
//
// Solidity: function refreshPrice((address,uint256,uint64,bytes)[] reports, uint256 notBefore) returns(uint256 price, uint256 oldestTimestamp)
func (_PerpsMarket *PerpsMarketTransactorSession) RefreshPrice(reports []IOracleVerifierSignedPriceReport, notBefore *big.Int) (*types.Transaction, error) {
	return _PerpsMarket.Contract.RefreshPrice(&_PerpsMarket.TransactOpts, reports, notBefore)
}

// RemoveLiquidity is a paid mutator transaction binding the contract method 0x05fe138b.
//
// Solidity: function removeLiquidity(uint256 assets, address receiver) returns()
func (_PerpsMarket *PerpsMarketTransactor) RemoveLiquidity(opts *bind.TransactOpts, assets *big.Int, receiver common.Address) (*types.Transaction, error) {
	return _PerpsMarket.contract.Transact(opts, "removeLiquidity", assets, receiver)
}

// RemoveLiquidity is a paid mutator transaction binding the contract method 0x05fe138b.
//
// Solidity: function removeLiquidity(uint256 assets, address receiver) returns()
func (_PerpsMarket *PerpsMarketSession) RemoveLiquidity(assets *big.Int, receiver common.Address) (*types.Transaction, error) {
	return _PerpsMarket.Contract.RemoveLiquidity(&_PerpsMarket.TransactOpts, assets, receiver)
}

// RemoveLiquidity is a paid mutator transaction binding the contract method 0x05fe138b.
//
// Solidity: function removeLiquidity(uint256 assets, address receiver) returns()
func (_PerpsMarket *PerpsMarketTransactorSession) RemoveLiquidity(assets *big.Int, receiver common.Address) (*types.Transaction, error) {
	return _PerpsMarket.Contract.RemoveLiquidity(&_PerpsMarket.TransactOpts, assets, receiver)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_PerpsMarket *PerpsMarketTransactor) SetAuthority(opts *bind.TransactOpts, newAuthority common.Address) (*types.Transaction, error) {
	return _PerpsMarket.contract.Transact(opts, "setAuthority", newAuthority)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_PerpsMarket *PerpsMarketSession) SetAuthority(newAuthority common.Address) (*types.Transaction, error) {
	return _PerpsMarket.Contract.SetAuthority(&_PerpsMarket.TransactOpts, newAuthority)
}

// SetAuthority is a paid mutator transaction binding the contract method 0x7a9e5e4b.
//
// Solidity: function setAuthority(address newAuthority) returns()
func (_PerpsMarket *PerpsMarketTransactorSession) SetAuthority(newAuthority common.Address) (*types.Transaction, error) {
	return _PerpsMarket.Contract.SetAuthority(&_PerpsMarket.TransactOpts, newAuthority)
}

// SetPaused is a paid mutator transaction binding the contract method 0x16c38b3c.
//
// Solidity: function setPaused(bool paused_) returns()
func (_PerpsMarket *PerpsMarketTransactor) SetPaused(opts *bind.TransactOpts, paused_ bool) (*types.Transaction, error) {
	return _PerpsMarket.contract.Transact(opts, "setPaused", paused_)
}

// SetPaused is a paid mutator transaction binding the contract method 0x16c38b3c.
//
// Solidity: function setPaused(bool paused_) returns()
func (_PerpsMarket *PerpsMarketSession) SetPaused(paused_ bool) (*types.Transaction, error) {
	return _PerpsMarket.Contract.SetPaused(&_PerpsMarket.TransactOpts, paused_)
}

// SetPaused is a paid mutator transaction binding the contract method 0x16c38b3c.
//
// Solidity: function setPaused(bool paused_) returns()
func (_PerpsMarket *PerpsMarketTransactorSession) SetPaused(paused_ bool) (*types.Transaction, error) {
	return _PerpsMarket.Contract.SetPaused(&_PerpsMarket.TransactOpts, paused_)
}

// SetRiskParams is a paid mutator transaction binding the contract method 0x58e89fbc.
//
// Solidity: function setRiskParams((uint128,uint128,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16,uint32,uint128,uint128,uint128,uint64,uint64,uint64,uint128,uint128) newParams) returns()
func (_PerpsMarket *PerpsMarketTransactor) SetRiskParams(opts *bind.TransactOpts, newParams IPerpsMarketRiskParams) (*types.Transaction, error) {
	return _PerpsMarket.contract.Transact(opts, "setRiskParams", newParams)
}

// SetRiskParams is a paid mutator transaction binding the contract method 0x58e89fbc.
//
// Solidity: function setRiskParams((uint128,uint128,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16,uint32,uint128,uint128,uint128,uint64,uint64,uint64,uint128,uint128) newParams) returns()
func (_PerpsMarket *PerpsMarketSession) SetRiskParams(newParams IPerpsMarketRiskParams) (*types.Transaction, error) {
	return _PerpsMarket.Contract.SetRiskParams(&_PerpsMarket.TransactOpts, newParams)
}

// SetRiskParams is a paid mutator transaction binding the contract method 0x58e89fbc.
//
// Solidity: function setRiskParams((uint128,uint128,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16,uint32,uint128,uint128,uint128,uint64,uint64,uint64,uint128,uint128) newParams) returns()
func (_PerpsMarket *PerpsMarketTransactorSession) SetRiskParams(newParams IPerpsMarketRiskParams) (*types.Transaction, error) {
	return _PerpsMarket.Contract.SetRiskParams(&_PerpsMarket.TransactOpts, newParams)
}

// PerpsMarketAuthorityUpdatedIterator is returned from FilterAuthorityUpdated and is used to iterate over the raw logs and unpacked data for AuthorityUpdated events raised by the PerpsMarket contract.
type PerpsMarketAuthorityUpdatedIterator struct {
	Event *PerpsMarketAuthorityUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketAuthorityUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketAuthorityUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketAuthorityUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketAuthorityUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketAuthorityUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketAuthorityUpdated represents a AuthorityUpdated event raised by the PerpsMarket contract.
type PerpsMarketAuthorityUpdated struct {
	Authority common.Address
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterAuthorityUpdated is a free log retrieval operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_PerpsMarket *PerpsMarketFilterer) FilterAuthorityUpdated(opts *bind.FilterOpts) (*PerpsMarketAuthorityUpdatedIterator, error) {

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "AuthorityUpdated")
	if err != nil {
		return nil, err
	}
	return &PerpsMarketAuthorityUpdatedIterator{contract: _PerpsMarket.contract, event: "AuthorityUpdated", logs: logs, sub: sub}, nil
}

// WatchAuthorityUpdated is a free log subscription operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_PerpsMarket *PerpsMarketFilterer) WatchAuthorityUpdated(opts *bind.WatchOpts, sink chan<- *PerpsMarketAuthorityUpdated) (event.Subscription, error) {

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "AuthorityUpdated")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketAuthorityUpdated)
				if err := _PerpsMarket.contract.UnpackLog(event, "AuthorityUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseAuthorityUpdated is a log parse operation binding the contract event 0x2f658b440c35314f52658ea8a740e05b284cdc84dc9ae01e891f21b8933e7cad.
//
// Solidity: event AuthorityUpdated(address authority)
func (_PerpsMarket *PerpsMarketFilterer) ParseAuthorityUpdated(log types.Log) (*PerpsMarketAuthorityUpdated, error) {
	event := new(PerpsMarketAuthorityUpdated)
	if err := _PerpsMarket.contract.UnpackLog(event, "AuthorityUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketFeesSettledIterator is returned from FilterFeesSettled and is used to iterate over the raw logs and unpacked data for FeesSettled events raised by the PerpsMarket contract.
type PerpsMarketFeesSettledIterator struct {
	Event *PerpsMarketFeesSettled // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketFeesSettledIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketFeesSettled)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketFeesSettled)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketFeesSettledIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketFeesSettledIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketFeesSettled represents a FeesSettled event raised by the PerpsMarket contract.
type PerpsMarketFeesSettled struct {
	Account    common.Address
	IsLong     bool
	BorrowFee  *big.Int
	FundingFee *big.Int
	Raw        types.Log // Blockchain specific contextual infos
}

// FilterFeesSettled is a free log retrieval operation binding the contract event 0xcd89ab71e4fff717bc4b3f6f54c4ceafe7ca140db3cbc7b783548a2378c4bcbe.
//
// Solidity: event FeesSettled(address indexed account, bool indexed isLong, uint256 borrowFee, int256 fundingFee)
func (_PerpsMarket *PerpsMarketFilterer) FilterFeesSettled(opts *bind.FilterOpts, account []common.Address, isLong []bool) (*PerpsMarketFeesSettledIterator, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "FeesSettled", accountRule, isLongRule)
	if err != nil {
		return nil, err
	}
	return &PerpsMarketFeesSettledIterator{contract: _PerpsMarket.contract, event: "FeesSettled", logs: logs, sub: sub}, nil
}

// WatchFeesSettled is a free log subscription operation binding the contract event 0xcd89ab71e4fff717bc4b3f6f54c4ceafe7ca140db3cbc7b783548a2378c4bcbe.
//
// Solidity: event FeesSettled(address indexed account, bool indexed isLong, uint256 borrowFee, int256 fundingFee)
func (_PerpsMarket *PerpsMarketFilterer) WatchFeesSettled(opts *bind.WatchOpts, sink chan<- *PerpsMarketFeesSettled, account []common.Address, isLong []bool) (event.Subscription, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "FeesSettled", accountRule, isLongRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketFeesSettled)
				if err := _PerpsMarket.contract.UnpackLog(event, "FeesSettled", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseFeesSettled is a log parse operation binding the contract event 0xcd89ab71e4fff717bc4b3f6f54c4ceafe7ca140db3cbc7b783548a2378c4bcbe.
//
// Solidity: event FeesSettled(address indexed account, bool indexed isLong, uint256 borrowFee, int256 fundingFee)
func (_PerpsMarket *PerpsMarketFilterer) ParseFeesSettled(log types.Log) (*PerpsMarketFeesSettled, error) {
	event := new(PerpsMarketFeesSettled)
	if err := _PerpsMarket.contract.UnpackLog(event, "FeesSettled", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketImpactPoolDistributedIterator is returned from FilterImpactPoolDistributed and is used to iterate over the raw logs and unpacked data for ImpactPoolDistributed events raised by the PerpsMarket contract.
type PerpsMarketImpactPoolDistributedIterator struct {
	Event *PerpsMarketImpactPoolDistributed // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketImpactPoolDistributedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketImpactPoolDistributed)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketImpactPoolDistributed)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketImpactPoolDistributedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketImpactPoolDistributedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketImpactPoolDistributed represents a ImpactPoolDistributed event raised by the PerpsMarket contract.
type PerpsMarketImpactPoolDistributed struct {
	Amount     *big.Int
	PoolAmount *big.Int
	Raw        types.Log // Blockchain specific contextual infos
}

// FilterImpactPoolDistributed is a free log retrieval operation binding the contract event 0x5eec77d9e91119545e011366d68748d275f35f7f1900bc9995632c6cac661014.
//
// Solidity: event ImpactPoolDistributed(uint256 amount, uint256 poolAmount)
func (_PerpsMarket *PerpsMarketFilterer) FilterImpactPoolDistributed(opts *bind.FilterOpts) (*PerpsMarketImpactPoolDistributedIterator, error) {

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "ImpactPoolDistributed")
	if err != nil {
		return nil, err
	}
	return &PerpsMarketImpactPoolDistributedIterator{contract: _PerpsMarket.contract, event: "ImpactPoolDistributed", logs: logs, sub: sub}, nil
}

// WatchImpactPoolDistributed is a free log subscription operation binding the contract event 0x5eec77d9e91119545e011366d68748d275f35f7f1900bc9995632c6cac661014.
//
// Solidity: event ImpactPoolDistributed(uint256 amount, uint256 poolAmount)
func (_PerpsMarket *PerpsMarketFilterer) WatchImpactPoolDistributed(opts *bind.WatchOpts, sink chan<- *PerpsMarketImpactPoolDistributed) (event.Subscription, error) {

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "ImpactPoolDistributed")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketImpactPoolDistributed)
				if err := _PerpsMarket.contract.UnpackLog(event, "ImpactPoolDistributed", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseImpactPoolDistributed is a log parse operation binding the contract event 0x5eec77d9e91119545e011366d68748d275f35f7f1900bc9995632c6cac661014.
//
// Solidity: event ImpactPoolDistributed(uint256 amount, uint256 poolAmount)
func (_PerpsMarket *PerpsMarketFilterer) ParseImpactPoolDistributed(log types.Log) (*PerpsMarketImpactPoolDistributed, error) {
	event := new(PerpsMarketImpactPoolDistributed)
	if err := _PerpsMarket.contract.UnpackLog(event, "ImpactPoolDistributed", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketIndicesAccruedIterator is returned from FilterIndicesAccrued and is used to iterate over the raw logs and unpacked data for IndicesAccrued events raised by the PerpsMarket contract.
type PerpsMarketIndicesAccruedIterator struct {
	Event *PerpsMarketIndicesAccrued // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketIndicesAccruedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketIndicesAccrued)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketIndicesAccrued)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketIndicesAccruedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketIndicesAccruedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketIndicesAccrued represents a IndicesAccrued event raised by the PerpsMarket contract.
type PerpsMarketIndicesAccrued struct {
	FundingRate      *big.Int
	FundingIndex     *big.Int
	BorrowIndexLong  *big.Int
	BorrowIndexShort *big.Int
	Raw              types.Log // Blockchain specific contextual infos
}

// FilterIndicesAccrued is a free log retrieval operation binding the contract event 0xb83c7e937be0ce352823f8301c14549fc8af60d5767d5f9b7022763660807075.
//
// Solidity: event IndicesAccrued(int256 fundingRate, int256 fundingIndex, uint256 borrowIndexLong, uint256 borrowIndexShort)
func (_PerpsMarket *PerpsMarketFilterer) FilterIndicesAccrued(opts *bind.FilterOpts) (*PerpsMarketIndicesAccruedIterator, error) {

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "IndicesAccrued")
	if err != nil {
		return nil, err
	}
	return &PerpsMarketIndicesAccruedIterator{contract: _PerpsMarket.contract, event: "IndicesAccrued", logs: logs, sub: sub}, nil
}

// WatchIndicesAccrued is a free log subscription operation binding the contract event 0xb83c7e937be0ce352823f8301c14549fc8af60d5767d5f9b7022763660807075.
//
// Solidity: event IndicesAccrued(int256 fundingRate, int256 fundingIndex, uint256 borrowIndexLong, uint256 borrowIndexShort)
func (_PerpsMarket *PerpsMarketFilterer) WatchIndicesAccrued(opts *bind.WatchOpts, sink chan<- *PerpsMarketIndicesAccrued) (event.Subscription, error) {

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "IndicesAccrued")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketIndicesAccrued)
				if err := _PerpsMarket.contract.UnpackLog(event, "IndicesAccrued", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseIndicesAccrued is a log parse operation binding the contract event 0xb83c7e937be0ce352823f8301c14549fc8af60d5767d5f9b7022763660807075.
//
// Solidity: event IndicesAccrued(int256 fundingRate, int256 fundingIndex, uint256 borrowIndexLong, uint256 borrowIndexShort)
func (_PerpsMarket *PerpsMarketFilterer) ParseIndicesAccrued(log types.Log) (*PerpsMarketIndicesAccrued, error) {
	event := new(PerpsMarketIndicesAccrued)
	if err := _PerpsMarket.contract.UnpackLog(event, "IndicesAccrued", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketLiquidityAddedIterator is returned from FilterLiquidityAdded and is used to iterate over the raw logs and unpacked data for LiquidityAdded events raised by the PerpsMarket contract.
type PerpsMarketLiquidityAddedIterator struct {
	Event *PerpsMarketLiquidityAdded // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketLiquidityAddedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketLiquidityAdded)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketLiquidityAdded)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketLiquidityAddedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketLiquidityAddedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketLiquidityAdded represents a LiquidityAdded event raised by the PerpsMarket contract.
type PerpsMarketLiquidityAdded struct {
	Assets     *big.Int
	PoolAmount *big.Int
	Raw        types.Log // Blockchain specific contextual infos
}

// FilterLiquidityAdded is a free log retrieval operation binding the contract event 0x38f8a0c92f4c5b0b6877f878cb4c0c8d348a47b76d716c8e78f425043df9515b.
//
// Solidity: event LiquidityAdded(uint256 assets, uint256 poolAmount)
func (_PerpsMarket *PerpsMarketFilterer) FilterLiquidityAdded(opts *bind.FilterOpts) (*PerpsMarketLiquidityAddedIterator, error) {

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "LiquidityAdded")
	if err != nil {
		return nil, err
	}
	return &PerpsMarketLiquidityAddedIterator{contract: _PerpsMarket.contract, event: "LiquidityAdded", logs: logs, sub: sub}, nil
}

// WatchLiquidityAdded is a free log subscription operation binding the contract event 0x38f8a0c92f4c5b0b6877f878cb4c0c8d348a47b76d716c8e78f425043df9515b.
//
// Solidity: event LiquidityAdded(uint256 assets, uint256 poolAmount)
func (_PerpsMarket *PerpsMarketFilterer) WatchLiquidityAdded(opts *bind.WatchOpts, sink chan<- *PerpsMarketLiquidityAdded) (event.Subscription, error) {

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "LiquidityAdded")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketLiquidityAdded)
				if err := _PerpsMarket.contract.UnpackLog(event, "LiquidityAdded", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseLiquidityAdded is a log parse operation binding the contract event 0x38f8a0c92f4c5b0b6877f878cb4c0c8d348a47b76d716c8e78f425043df9515b.
//
// Solidity: event LiquidityAdded(uint256 assets, uint256 poolAmount)
func (_PerpsMarket *PerpsMarketFilterer) ParseLiquidityAdded(log types.Log) (*PerpsMarketLiquidityAdded, error) {
	event := new(PerpsMarketLiquidityAdded)
	if err := _PerpsMarket.contract.UnpackLog(event, "LiquidityAdded", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketLiquidityRemovedIterator is returned from FilterLiquidityRemoved and is used to iterate over the raw logs and unpacked data for LiquidityRemoved events raised by the PerpsMarket contract.
type PerpsMarketLiquidityRemovedIterator struct {
	Event *PerpsMarketLiquidityRemoved // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketLiquidityRemovedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketLiquidityRemoved)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketLiquidityRemoved)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketLiquidityRemovedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketLiquidityRemovedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketLiquidityRemoved represents a LiquidityRemoved event raised by the PerpsMarket contract.
type PerpsMarketLiquidityRemoved struct {
	Assets     *big.Int
	Receiver   common.Address
	PoolAmount *big.Int
	Raw        types.Log // Blockchain specific contextual infos
}

// FilterLiquidityRemoved is a free log retrieval operation binding the contract event 0x7cd78db3fa0f169740484c879803073b63a35c4c5d82f02312e7aa988eee8554.
//
// Solidity: event LiquidityRemoved(uint256 assets, address indexed receiver, uint256 poolAmount)
func (_PerpsMarket *PerpsMarketFilterer) FilterLiquidityRemoved(opts *bind.FilterOpts, receiver []common.Address) (*PerpsMarketLiquidityRemovedIterator, error) {

	var receiverRule []interface{}
	for _, receiverItem := range receiver {
		receiverRule = append(receiverRule, receiverItem)
	}

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "LiquidityRemoved", receiverRule)
	if err != nil {
		return nil, err
	}
	return &PerpsMarketLiquidityRemovedIterator{contract: _PerpsMarket.contract, event: "LiquidityRemoved", logs: logs, sub: sub}, nil
}

// WatchLiquidityRemoved is a free log subscription operation binding the contract event 0x7cd78db3fa0f169740484c879803073b63a35c4c5d82f02312e7aa988eee8554.
//
// Solidity: event LiquidityRemoved(uint256 assets, address indexed receiver, uint256 poolAmount)
func (_PerpsMarket *PerpsMarketFilterer) WatchLiquidityRemoved(opts *bind.WatchOpts, sink chan<- *PerpsMarketLiquidityRemoved, receiver []common.Address) (event.Subscription, error) {

	var receiverRule []interface{}
	for _, receiverItem := range receiver {
		receiverRule = append(receiverRule, receiverItem)
	}

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "LiquidityRemoved", receiverRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketLiquidityRemoved)
				if err := _PerpsMarket.contract.UnpackLog(event, "LiquidityRemoved", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseLiquidityRemoved is a log parse operation binding the contract event 0x7cd78db3fa0f169740484c879803073b63a35c4c5d82f02312e7aa988eee8554.
//
// Solidity: event LiquidityRemoved(uint256 assets, address indexed receiver, uint256 poolAmount)
func (_PerpsMarket *PerpsMarketFilterer) ParseLiquidityRemoved(log types.Log) (*PerpsMarketLiquidityRemoved, error) {
	event := new(PerpsMarketLiquidityRemoved)
	if err := _PerpsMarket.contract.UnpackLog(event, "LiquidityRemoved", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketPausedSetIterator is returned from FilterPausedSet and is used to iterate over the raw logs and unpacked data for PausedSet events raised by the PerpsMarket contract.
type PerpsMarketPausedSetIterator struct {
	Event *PerpsMarketPausedSet // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketPausedSetIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketPausedSet)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketPausedSet)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketPausedSetIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketPausedSetIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketPausedSet represents a PausedSet event raised by the PerpsMarket contract.
type PerpsMarketPausedSet struct {
	Paused bool
	Raw    types.Log // Blockchain specific contextual infos
}

// FilterPausedSet is a free log retrieval operation binding the contract event 0x40db37ff5c0bdc2c427fbb2078c8f24afea940abac0e3c23bb4ea3bf2da2b212.
//
// Solidity: event PausedSet(bool paused)
func (_PerpsMarket *PerpsMarketFilterer) FilterPausedSet(opts *bind.FilterOpts) (*PerpsMarketPausedSetIterator, error) {

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "PausedSet")
	if err != nil {
		return nil, err
	}
	return &PerpsMarketPausedSetIterator{contract: _PerpsMarket.contract, event: "PausedSet", logs: logs, sub: sub}, nil
}

// WatchPausedSet is a free log subscription operation binding the contract event 0x40db37ff5c0bdc2c427fbb2078c8f24afea940abac0e3c23bb4ea3bf2da2b212.
//
// Solidity: event PausedSet(bool paused)
func (_PerpsMarket *PerpsMarketFilterer) WatchPausedSet(opts *bind.WatchOpts, sink chan<- *PerpsMarketPausedSet) (event.Subscription, error) {

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "PausedSet")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketPausedSet)
				if err := _PerpsMarket.contract.UnpackLog(event, "PausedSet", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParsePausedSet is a log parse operation binding the contract event 0x40db37ff5c0bdc2c427fbb2078c8f24afea940abac0e3c23bb4ea3bf2da2b212.
//
// Solidity: event PausedSet(bool paused)
func (_PerpsMarket *PerpsMarketFilterer) ParsePausedSet(log types.Log) (*PerpsMarketPausedSet, error) {
	event := new(PerpsMarketPausedSet)
	if err := _PerpsMarket.contract.UnpackLog(event, "PausedSet", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketPositionAutoDeleveragedIterator is returned from FilterPositionAutoDeleveraged and is used to iterate over the raw logs and unpacked data for PositionAutoDeleveraged events raised by the PerpsMarket contract.
type PerpsMarketPositionAutoDeleveragedIterator struct {
	Event *PerpsMarketPositionAutoDeleveraged // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketPositionAutoDeleveragedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketPositionAutoDeleveraged)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketPositionAutoDeleveraged)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketPositionAutoDeleveragedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketPositionAutoDeleveragedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketPositionAutoDeleveraged represents a PositionAutoDeleveraged event raised by the PerpsMarket contract.
type PerpsMarketPositionAutoDeleveraged struct {
	Account         common.Address
	IsLong          bool
	SizeDeltaUsd    *big.Int
	Price           *big.Int
	RealizedPnl     *big.Int
	AmountOut       *big.Int
	PnlFactorBefore *big.Int
	PnlFactorAfter  *big.Int
	Raw             types.Log // Blockchain specific contextual infos
}

// FilterPositionAutoDeleveraged is a free log retrieval operation binding the contract event 0x6a550c0cf4f1e78a715b619071c4b654c2f94e497b712c334b33f64f6a81948a.
//
// Solidity: event PositionAutoDeleveraged(address indexed account, bool indexed isLong, uint256 sizeDeltaUsd, uint256 price, int256 realizedPnl, uint256 amountOut, uint256 pnlFactorBefore, uint256 pnlFactorAfter)
func (_PerpsMarket *PerpsMarketFilterer) FilterPositionAutoDeleveraged(opts *bind.FilterOpts, account []common.Address, isLong []bool) (*PerpsMarketPositionAutoDeleveragedIterator, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "PositionAutoDeleveraged", accountRule, isLongRule)
	if err != nil {
		return nil, err
	}
	return &PerpsMarketPositionAutoDeleveragedIterator{contract: _PerpsMarket.contract, event: "PositionAutoDeleveraged", logs: logs, sub: sub}, nil
}

// WatchPositionAutoDeleveraged is a free log subscription operation binding the contract event 0x6a550c0cf4f1e78a715b619071c4b654c2f94e497b712c334b33f64f6a81948a.
//
// Solidity: event PositionAutoDeleveraged(address indexed account, bool indexed isLong, uint256 sizeDeltaUsd, uint256 price, int256 realizedPnl, uint256 amountOut, uint256 pnlFactorBefore, uint256 pnlFactorAfter)
func (_PerpsMarket *PerpsMarketFilterer) WatchPositionAutoDeleveraged(opts *bind.WatchOpts, sink chan<- *PerpsMarketPositionAutoDeleveraged, account []common.Address, isLong []bool) (event.Subscription, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "PositionAutoDeleveraged", accountRule, isLongRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketPositionAutoDeleveraged)
				if err := _PerpsMarket.contract.UnpackLog(event, "PositionAutoDeleveraged", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParsePositionAutoDeleveraged is a log parse operation binding the contract event 0x6a550c0cf4f1e78a715b619071c4b654c2f94e497b712c334b33f64f6a81948a.
//
// Solidity: event PositionAutoDeleveraged(address indexed account, bool indexed isLong, uint256 sizeDeltaUsd, uint256 price, int256 realizedPnl, uint256 amountOut, uint256 pnlFactorBefore, uint256 pnlFactorAfter)
func (_PerpsMarket *PerpsMarketFilterer) ParsePositionAutoDeleveraged(log types.Log) (*PerpsMarketPositionAutoDeleveraged, error) {
	event := new(PerpsMarketPositionAutoDeleveraged)
	if err := _PerpsMarket.contract.UnpackLog(event, "PositionAutoDeleveraged", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketPositionDecreasedIterator is returned from FilterPositionDecreased and is used to iterate over the raw logs and unpacked data for PositionDecreased events raised by the PerpsMarket contract.
type PerpsMarketPositionDecreasedIterator struct {
	Event *PerpsMarketPositionDecreased // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketPositionDecreasedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketPositionDecreased)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketPositionDecreased)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketPositionDecreasedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketPositionDecreasedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketPositionDecreased represents a PositionDecreased event raised by the PerpsMarket contract.
type PerpsMarketPositionDecreased struct {
	Account        common.Address
	IsLong         bool
	SizeDeltaUsd   *big.Int
	Price          *big.Int
	RealizedPnl    *big.Int
	PositionFee    *big.Int
	PriceImpactUsd *big.Int
	AmountOut      *big.Int
	BadDebt        *big.Int
	Raw            types.Log // Blockchain specific contextual infos
}

// FilterPositionDecreased is a free log retrieval operation binding the contract event 0x69f7df3f066d4bddb8a8f21c3381f50392d787a0a29c4e36dc03d840cd0a05dc.
//
// Solidity: event PositionDecreased(address indexed account, bool indexed isLong, uint256 sizeDeltaUsd, uint256 price, int256 realizedPnl, uint256 positionFee, int256 priceImpactUsd, uint256 amountOut, uint256 badDebt)
func (_PerpsMarket *PerpsMarketFilterer) FilterPositionDecreased(opts *bind.FilterOpts, account []common.Address, isLong []bool) (*PerpsMarketPositionDecreasedIterator, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "PositionDecreased", accountRule, isLongRule)
	if err != nil {
		return nil, err
	}
	return &PerpsMarketPositionDecreasedIterator{contract: _PerpsMarket.contract, event: "PositionDecreased", logs: logs, sub: sub}, nil
}

// WatchPositionDecreased is a free log subscription operation binding the contract event 0x69f7df3f066d4bddb8a8f21c3381f50392d787a0a29c4e36dc03d840cd0a05dc.
//
// Solidity: event PositionDecreased(address indexed account, bool indexed isLong, uint256 sizeDeltaUsd, uint256 price, int256 realizedPnl, uint256 positionFee, int256 priceImpactUsd, uint256 amountOut, uint256 badDebt)
func (_PerpsMarket *PerpsMarketFilterer) WatchPositionDecreased(opts *bind.WatchOpts, sink chan<- *PerpsMarketPositionDecreased, account []common.Address, isLong []bool) (event.Subscription, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "PositionDecreased", accountRule, isLongRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketPositionDecreased)
				if err := _PerpsMarket.contract.UnpackLog(event, "PositionDecreased", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParsePositionDecreased is a log parse operation binding the contract event 0x69f7df3f066d4bddb8a8f21c3381f50392d787a0a29c4e36dc03d840cd0a05dc.
//
// Solidity: event PositionDecreased(address indexed account, bool indexed isLong, uint256 sizeDeltaUsd, uint256 price, int256 realizedPnl, uint256 positionFee, int256 priceImpactUsd, uint256 amountOut, uint256 badDebt)
func (_PerpsMarket *PerpsMarketFilterer) ParsePositionDecreased(log types.Log) (*PerpsMarketPositionDecreased, error) {
	event := new(PerpsMarketPositionDecreased)
	if err := _PerpsMarket.contract.UnpackLog(event, "PositionDecreased", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketPositionIncreasedIterator is returned from FilterPositionIncreased and is used to iterate over the raw logs and unpacked data for PositionIncreased events raised by the PerpsMarket contract.
type PerpsMarketPositionIncreasedIterator struct {
	Event *PerpsMarketPositionIncreased // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketPositionIncreasedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketPositionIncreased)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketPositionIncreased)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketPositionIncreasedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketPositionIncreasedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketPositionIncreased represents a PositionIncreased event raised by the PerpsMarket contract.
type PerpsMarketPositionIncreased struct {
	Account         common.Address
	IsLong          bool
	SizeDeltaUsd    *big.Int
	CollateralDelta *big.Int
	Price           *big.Int
	PositionFee     *big.Int
	PriceImpactUsd  *big.Int
	SizeUsd         *big.Int
	Collateral      *big.Int
	Raw             types.Log // Blockchain specific contextual infos
}

// FilterPositionIncreased is a free log retrieval operation binding the contract event 0x068fd7e47bc720a0cdc70aa9432d25f2c67fb9ede6ffd032a829d62b26ae5d7b.
//
// Solidity: event PositionIncreased(address indexed account, bool indexed isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 price, uint256 positionFee, int256 priceImpactUsd, uint256 sizeUsd, uint256 collateral)
func (_PerpsMarket *PerpsMarketFilterer) FilterPositionIncreased(opts *bind.FilterOpts, account []common.Address, isLong []bool) (*PerpsMarketPositionIncreasedIterator, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "PositionIncreased", accountRule, isLongRule)
	if err != nil {
		return nil, err
	}
	return &PerpsMarketPositionIncreasedIterator{contract: _PerpsMarket.contract, event: "PositionIncreased", logs: logs, sub: sub}, nil
}

// WatchPositionIncreased is a free log subscription operation binding the contract event 0x068fd7e47bc720a0cdc70aa9432d25f2c67fb9ede6ffd032a829d62b26ae5d7b.
//
// Solidity: event PositionIncreased(address indexed account, bool indexed isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 price, uint256 positionFee, int256 priceImpactUsd, uint256 sizeUsd, uint256 collateral)
func (_PerpsMarket *PerpsMarketFilterer) WatchPositionIncreased(opts *bind.WatchOpts, sink chan<- *PerpsMarketPositionIncreased, account []common.Address, isLong []bool) (event.Subscription, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "PositionIncreased", accountRule, isLongRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketPositionIncreased)
				if err := _PerpsMarket.contract.UnpackLog(event, "PositionIncreased", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParsePositionIncreased is a log parse operation binding the contract event 0x068fd7e47bc720a0cdc70aa9432d25f2c67fb9ede6ffd032a829d62b26ae5d7b.
//
// Solidity: event PositionIncreased(address indexed account, bool indexed isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 price, uint256 positionFee, int256 priceImpactUsd, uint256 sizeUsd, uint256 collateral)
func (_PerpsMarket *PerpsMarketFilterer) ParsePositionIncreased(log types.Log) (*PerpsMarketPositionIncreased, error) {
	event := new(PerpsMarketPositionIncreased)
	if err := _PerpsMarket.contract.UnpackLog(event, "PositionIncreased", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketPositionLiquidatedIterator is returned from FilterPositionLiquidated and is used to iterate over the raw logs and unpacked data for PositionLiquidated events raised by the PerpsMarket contract.
type PerpsMarketPositionLiquidatedIterator struct {
	Event *PerpsMarketPositionLiquidated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketPositionLiquidatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketPositionLiquidated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketPositionLiquidated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketPositionLiquidatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketPositionLiquidatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketPositionLiquidated represents a PositionLiquidated event raised by the PerpsMarket contract.
type PerpsMarketPositionLiquidated struct {
	Account             common.Address
	IsLong              bool
	Keeper              common.Address
	Price               *big.Int
	SizeUsd             *big.Int
	RemainingCollateral *big.Int
	KeeperReward        *big.Int
	AmountOut           *big.Int
	BadDebt             *big.Int
	Raw                 types.Log // Blockchain specific contextual infos
}

// FilterPositionLiquidated is a free log retrieval operation binding the contract event 0xc169e66b719a87fd1cb816cf4c8bb389307ca8f0fdfd4a73ee1022611196c7de.
//
// Solidity: event PositionLiquidated(address indexed account, bool indexed isLong, address indexed keeper, uint256 price, uint256 sizeUsd, int256 remainingCollateral, uint256 keeperReward, uint256 amountOut, uint256 badDebt)
func (_PerpsMarket *PerpsMarketFilterer) FilterPositionLiquidated(opts *bind.FilterOpts, account []common.Address, isLong []bool, keeper []common.Address) (*PerpsMarketPositionLiquidatedIterator, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}
	var keeperRule []interface{}
	for _, keeperItem := range keeper {
		keeperRule = append(keeperRule, keeperItem)
	}

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "PositionLiquidated", accountRule, isLongRule, keeperRule)
	if err != nil {
		return nil, err
	}
	return &PerpsMarketPositionLiquidatedIterator{contract: _PerpsMarket.contract, event: "PositionLiquidated", logs: logs, sub: sub}, nil
}

// WatchPositionLiquidated is a free log subscription operation binding the contract event 0xc169e66b719a87fd1cb816cf4c8bb389307ca8f0fdfd4a73ee1022611196c7de.
//
// Solidity: event PositionLiquidated(address indexed account, bool indexed isLong, address indexed keeper, uint256 price, uint256 sizeUsd, int256 remainingCollateral, uint256 keeperReward, uint256 amountOut, uint256 badDebt)
func (_PerpsMarket *PerpsMarketFilterer) WatchPositionLiquidated(opts *bind.WatchOpts, sink chan<- *PerpsMarketPositionLiquidated, account []common.Address, isLong []bool, keeper []common.Address) (event.Subscription, error) {

	var accountRule []interface{}
	for _, accountItem := range account {
		accountRule = append(accountRule, accountItem)
	}
	var isLongRule []interface{}
	for _, isLongItem := range isLong {
		isLongRule = append(isLongRule, isLongItem)
	}
	var keeperRule []interface{}
	for _, keeperItem := range keeper {
		keeperRule = append(keeperRule, keeperItem)
	}

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "PositionLiquidated", accountRule, isLongRule, keeperRule)
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketPositionLiquidated)
				if err := _PerpsMarket.contract.UnpackLog(event, "PositionLiquidated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParsePositionLiquidated is a log parse operation binding the contract event 0xc169e66b719a87fd1cb816cf4c8bb389307ca8f0fdfd4a73ee1022611196c7de.
//
// Solidity: event PositionLiquidated(address indexed account, bool indexed isLong, address indexed keeper, uint256 price, uint256 sizeUsd, int256 remainingCollateral, uint256 keeperReward, uint256 amountOut, uint256 badDebt)
func (_PerpsMarket *PerpsMarketFilterer) ParsePositionLiquidated(log types.Log) (*PerpsMarketPositionLiquidated, error) {
	event := new(PerpsMarketPositionLiquidated)
	if err := _PerpsMarket.contract.UnpackLog(event, "PositionLiquidated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketPriceUpdatedIterator is returned from FilterPriceUpdated and is used to iterate over the raw logs and unpacked data for PriceUpdated events raised by the PerpsMarket contract.
type PerpsMarketPriceUpdatedIterator struct {
	Event *PerpsMarketPriceUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketPriceUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketPriceUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketPriceUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketPriceUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketPriceUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketPriceUpdated represents a PriceUpdated event raised by the PerpsMarket contract.
type PerpsMarketPriceUpdated struct {
	Price     *big.Int
	Timestamp *big.Int
	Raw       types.Log // Blockchain specific contextual infos
}

// FilterPriceUpdated is a free log retrieval operation binding the contract event 0x945c1c4e99aa89f648fbfe3df471b916f719e16d960fcec0737d4d56bd696838.
//
// Solidity: event PriceUpdated(uint256 price, uint256 timestamp)
func (_PerpsMarket *PerpsMarketFilterer) FilterPriceUpdated(opts *bind.FilterOpts) (*PerpsMarketPriceUpdatedIterator, error) {

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "PriceUpdated")
	if err != nil {
		return nil, err
	}
	return &PerpsMarketPriceUpdatedIterator{contract: _PerpsMarket.contract, event: "PriceUpdated", logs: logs, sub: sub}, nil
}

// WatchPriceUpdated is a free log subscription operation binding the contract event 0x945c1c4e99aa89f648fbfe3df471b916f719e16d960fcec0737d4d56bd696838.
//
// Solidity: event PriceUpdated(uint256 price, uint256 timestamp)
func (_PerpsMarket *PerpsMarketFilterer) WatchPriceUpdated(opts *bind.WatchOpts, sink chan<- *PerpsMarketPriceUpdated) (event.Subscription, error) {

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "PriceUpdated")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketPriceUpdated)
				if err := _PerpsMarket.contract.UnpackLog(event, "PriceUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParsePriceUpdated is a log parse operation binding the contract event 0x945c1c4e99aa89f648fbfe3df471b916f719e16d960fcec0737d4d56bd696838.
//
// Solidity: event PriceUpdated(uint256 price, uint256 timestamp)
func (_PerpsMarket *PerpsMarketFilterer) ParsePriceUpdated(log types.Log) (*PerpsMarketPriceUpdated, error) {
	event := new(PerpsMarketPriceUpdated)
	if err := _PerpsMarket.contract.UnpackLog(event, "PriceUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}

// PerpsMarketRiskParamsUpdatedIterator is returned from FilterRiskParamsUpdated and is used to iterate over the raw logs and unpacked data for RiskParamsUpdated events raised by the PerpsMarket contract.
type PerpsMarketRiskParamsUpdatedIterator struct {
	Event *PerpsMarketRiskParamsUpdated // Event containing the contract specifics and raw log

	contract *bind.BoundContract // Generic contract to use for unpacking event data
	event    string              // Event name to use for unpacking event data

	logs chan types.Log        // Log channel receiving the found contract events
	sub  ethereum.Subscription // Subscription for errors, completion and termination
	done bool                  // Whether the subscription completed delivering logs
	fail error                 // Occurred error to stop iteration
}

// Next advances the iterator to the subsequent event, returning whether there
// are any more events found. In case of a retrieval or parsing error, false is
// returned and Error() can be queried for the exact failure.
func (it *PerpsMarketRiskParamsUpdatedIterator) Next() bool {
	// If the iterator failed, stop iterating
	if it.fail != nil {
		return false
	}
	// If the iterator completed, deliver directly whatever's available
	if it.done {
		select {
		case log := <-it.logs:
			it.Event = new(PerpsMarketRiskParamsUpdated)
			if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
				it.fail = err
				return false
			}
			it.Event.Raw = log
			return true

		default:
			return false
		}
	}
	// Iterator still in progress, wait for either a data or an error event
	select {
	case log := <-it.logs:
		it.Event = new(PerpsMarketRiskParamsUpdated)
		if err := it.contract.UnpackLog(it.Event, it.event, log); err != nil {
			it.fail = err
			return false
		}
		it.Event.Raw = log
		return true

	case err := <-it.sub.Err():
		it.done = true
		it.fail = err
		return it.Next()
	}
}

// Error returns any retrieval or parsing error occurred during filtering.
func (it *PerpsMarketRiskParamsUpdatedIterator) Error() error {
	return it.fail
}

// Close terminates the iteration process, releasing any pending underlying
// resources.
func (it *PerpsMarketRiskParamsUpdatedIterator) Close() error {
	it.sub.Unsubscribe()
	return nil
}

// PerpsMarketRiskParamsUpdated represents a RiskParamsUpdated event raised by the PerpsMarket contract.
type PerpsMarketRiskParamsUpdated struct {
	Params IPerpsMarketRiskParams
	Raw    types.Log // Blockchain specific contextual infos
}

// FilterRiskParamsUpdated is a free log retrieval operation binding the contract event 0xc7f36dc8e3119a25b581eae687b05812e2a091f775868e748400edb677136f95.
//
// Solidity: event RiskParamsUpdated((uint128,uint128,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16,uint32,uint128,uint128,uint128,uint64,uint64,uint64,uint128,uint128) params)
func (_PerpsMarket *PerpsMarketFilterer) FilterRiskParamsUpdated(opts *bind.FilterOpts) (*PerpsMarketRiskParamsUpdatedIterator, error) {

	logs, sub, err := _PerpsMarket.contract.FilterLogs(opts, "RiskParamsUpdated")
	if err != nil {
		return nil, err
	}
	return &PerpsMarketRiskParamsUpdatedIterator{contract: _PerpsMarket.contract, event: "RiskParamsUpdated", logs: logs, sub: sub}, nil
}

// WatchRiskParamsUpdated is a free log subscription operation binding the contract event 0xc7f36dc8e3119a25b581eae687b05812e2a091f775868e748400edb677136f95.
//
// Solidity: event RiskParamsUpdated((uint128,uint128,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16,uint32,uint128,uint128,uint128,uint64,uint64,uint64,uint128,uint128) params)
func (_PerpsMarket *PerpsMarketFilterer) WatchRiskParamsUpdated(opts *bind.WatchOpts, sink chan<- *PerpsMarketRiskParamsUpdated) (event.Subscription, error) {

	logs, sub, err := _PerpsMarket.contract.WatchLogs(opts, "RiskParamsUpdated")
	if err != nil {
		return nil, err
	}
	return event.NewSubscription(func(quit <-chan struct{}) error {
		defer sub.Unsubscribe()
		for {
			select {
			case log := <-logs:
				// New log arrived, parse the event and forward to the user
				event := new(PerpsMarketRiskParamsUpdated)
				if err := _PerpsMarket.contract.UnpackLog(event, "RiskParamsUpdated", log); err != nil {
					// If the signature doesn't match, skip this log.
					if errors.Is(err, bind.ErrEventSignatureMismatch) {
						continue
					}
					return err
				}
				event.Raw = log

				select {
				case sink <- event:
				case err := <-sub.Err():
					return err
				case <-quit:
					return nil
				}
			case err := <-sub.Err():
				return err
			case <-quit:
				return nil
			}
		}
	}), nil
}

// ParseRiskParamsUpdated is a log parse operation binding the contract event 0xc7f36dc8e3119a25b581eae687b05812e2a091f775868e748400edb677136f95.
//
// Solidity: event RiskParamsUpdated((uint128,uint128,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16,uint32,uint128,uint128,uint128,uint64,uint64,uint64,uint128,uint128) params)
func (_PerpsMarket *PerpsMarketFilterer) ParseRiskParamsUpdated(log types.Log) (*PerpsMarketRiskParamsUpdated, error) {
	event := new(PerpsMarketRiskParamsUpdated)
	if err := _PerpsMarket.contract.UnpackLog(event, "RiskParamsUpdated", log); err != nil {
		return nil, err
	}
	event.Raw = log
	return event, nil
}
