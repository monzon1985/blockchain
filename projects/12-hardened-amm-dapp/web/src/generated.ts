import {
  createUseReadContract,
  createUseWriteContract,
  createUseSimulateContract,
  createUseWatchContractEvent,
} from 'wagmi/codegen'

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// AMMFactory
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export const ammFactoryAbi = [
  {
    type: 'constructor',
    inputs: [
      { name: 'initialOwner', internalType: 'address', type: 'address' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'PAIR_INIT_CODE_HASH',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'acceptOwnership',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    name: 'allPairs',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'allPairsLength',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'tokenA', internalType: 'address', type: 'address' },
      { name: 'tokenB', internalType: 'address', type: 'address' },
    ],
    name: 'createPair',
    outputs: [{ name: 'pair', internalType: 'address', type: 'address' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'feeTo',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'tokenA', internalType: 'address', type: 'address' },
      { name: 'tokenB', internalType: 'address', type: 'address' },
    ],
    name: 'getPair',
    outputs: [{ name: 'pair', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'owner',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'parameters',
    outputs: [
      { name: 'token0', internalType: 'address', type: 'address' },
      { name: 'token1', internalType: 'address', type: 'address' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'pendingOwner',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'renounceOwnership',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'newFeeTo', internalType: 'address', type: 'address' }],
    name: 'setFeeTo',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'newOwner', internalType: 'address', type: 'address' }],
    name: 'transferOwnership',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'previousFeeTo',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'newFeeTo',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'FeeToUpdated',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'previousOwner',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'newOwner',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'OwnershipTransferStarted',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'previousOwner',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'newOwner',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'OwnershipTransferred',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'token0',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'token1',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'pair',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'pairCount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'PairCreated',
  },
  {
    type: 'error',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'IdenticalAddresses',
  },
  {
    type: 'error',
    inputs: [{ name: 'owner', internalType: 'address', type: 'address' }],
    name: 'OwnableInvalidOwner',
  },
  {
    type: 'error',
    inputs: [{ name: 'account', internalType: 'address', type: 'address' }],
    name: 'OwnableUnauthorizedAccount',
  },
  {
    type: 'error',
    inputs: [{ name: 'pair', internalType: 'address', type: 'address' }],
    name: 'PairExists',
  },
  {
    type: 'error',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'TokenHasNoCode',
  },
  { type: 'error', inputs: [], name: 'ZeroAddress' },
] as const

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// AMMPair
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export const ammPairAbi = [
  { type: 'constructor', inputs: [], stateMutability: 'nonpayable' },
  {
    type: 'function',
    inputs: [],
    name: 'CALLBACK_SUCCESS',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'DOMAIN_SEPARATOR',
    outputs: [{ name: 'result', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MINIMUM_LIQUIDITY',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'owner', internalType: 'address', type: 'address' },
      { name: 'spender', internalType: 'address', type: 'address' },
    ],
    name: 'allowance',
    outputs: [{ name: 'result', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'spender', internalType: 'address', type: 'address' },
      { name: 'amount', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'approve',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'owner', internalType: 'address', type: 'address' }],
    name: 'balanceOf',
    outputs: [{ name: 'result', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'to', internalType: 'address', type: 'address' }],
    name: 'burn',
    outputs: [
      { name: 'amount0', internalType: 'uint256', type: 'uint256' },
      { name: 'amount1', internalType: 'uint256', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'decimals',
    outputs: [{ name: '', internalType: 'uint8', type: 'uint8' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'factory',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'getReserves',
    outputs: [
      { name: '_reserve0', internalType: 'uint112', type: 'uint112' },
      { name: '_reserve1', internalType: 'uint112', type: 'uint112' },
      { name: '_blockTimestampLast', internalType: 'uint32', type: 'uint32' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'isLocked',
    outputs: [{ name: 'locked', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'kLast',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'to', internalType: 'address', type: 'address' }],
    name: 'mint',
    outputs: [{ name: 'liquidity', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'name',
    outputs: [{ name: '', internalType: 'string', type: 'string' }],
    stateMutability: 'pure',
  },
  {
    type: 'function',
    inputs: [{ name: 'owner', internalType: 'address', type: 'address' }],
    name: 'nonces',
    outputs: [{ name: 'result', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'owner', internalType: 'address', type: 'address' },
      { name: 'spender', internalType: 'address', type: 'address' },
      { name: 'value', internalType: 'uint256', type: 'uint256' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
      { name: 'v', internalType: 'uint8', type: 'uint8' },
      { name: 'r', internalType: 'bytes32', type: 'bytes32' },
      { name: 's', internalType: 'bytes32', type: 'bytes32' },
    ],
    name: 'permit',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'price0CumulativeLast',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'price1CumulativeLast',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'to', internalType: 'address', type: 'address' }],
    name: 'skim',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'amount0Out', internalType: 'uint256', type: 'uint256' },
      { name: 'amount1Out', internalType: 'uint256', type: 'uint256' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'data', internalType: 'bytes', type: 'bytes' },
    ],
    name: 'swap',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'symbol',
    outputs: [{ name: '', internalType: 'string', type: 'string' }],
    stateMutability: 'pure',
  },
  {
    type: 'function',
    inputs: [],
    name: 'sync',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'token0',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'token1',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'totalSupply',
    outputs: [{ name: 'result', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'amount', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'transfer',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'from', internalType: 'address', type: 'address' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'amount', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'transferFrom',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'owner',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'spender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'amount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'Approval',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'sender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'amount0',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'amount1',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      { name: 'to', internalType: 'address', type: 'address', indexed: true },
    ],
    name: 'Burn',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'sender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'amount0',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'amount1',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'Mint',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'sender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'amount0In',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'amount1In',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'amount0Out',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'amount1Out',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      { name: 'to', internalType: 'address', type: 'address', indexed: true },
    ],
    name: 'Swap',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'reserve0',
        internalType: 'uint112',
        type: 'uint112',
        indexed: false,
      },
      {
        name: 'reserve1',
        internalType: 'uint112',
        type: 'uint112',
        indexed: false,
      },
    ],
    name: 'Sync',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'from', internalType: 'address', type: 'address', indexed: true },
      { name: 'to', internalType: 'address', type: 'address', indexed: true },
      {
        name: 'amount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'Transfer',
  },
  { type: 'error', inputs: [], name: 'AllowanceOverflow' },
  { type: 'error', inputs: [], name: 'AllowanceUnderflow' },
  {
    type: 'error',
    inputs: [{ name: 'to', internalType: 'address', type: 'address' }],
    name: 'CallbackTargetNotContract',
  },
  { type: 'error', inputs: [], name: 'InsufficientAllowance' },
  { type: 'error', inputs: [], name: 'InsufficientBalance' },
  { type: 'error', inputs: [], name: 'InsufficientInputAmount' },
  {
    type: 'error',
    inputs: [
      { name: 'amount0Out', internalType: 'uint256', type: 'uint256' },
      { name: 'amount1Out', internalType: 'uint256', type: 'uint256' },
      { name: 'reserve0', internalType: 'uint112', type: 'uint112' },
      { name: 'reserve1', internalType: 'uint112', type: 'uint112' },
    ],
    name: 'InsufficientLiquidity',
  },
  {
    type: 'error',
    inputs: [
      { name: 'amount0', internalType: 'uint256', type: 'uint256' },
      { name: 'amount1', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InsufficientLiquidityBurned',
  },
  {
    type: 'error',
    inputs: [{ name: 'liquidity', internalType: 'uint256', type: 'uint256' }],
    name: 'InsufficientLiquidityMinted',
  },
  { type: 'error', inputs: [], name: 'InsufficientOutputAmount' },
  {
    type: 'error',
    inputs: [{ name: 'returned', internalType: 'bytes32', type: 'bytes32' }],
    name: 'InvalidCallbackReturn',
  },
  { type: 'error', inputs: [], name: 'InvalidPermit' },
  {
    type: 'error',
    inputs: [{ name: 'to', internalType: 'address', type: 'address' }],
    name: 'InvalidTo',
  },
  {
    type: 'error',
    inputs: [
      { name: 'balanceProduct', internalType: 'uint256', type: 'uint256' },
      { name: 'reserveProduct', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'K',
  },
  {
    type: 'error',
    inputs: [
      { name: 'balance0', internalType: 'uint256', type: 'uint256' },
      { name: 'balance1', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'Overflow',
  },
  { type: 'error', inputs: [], name: 'Permit2AllowanceIsFixedAtInfinity' },
  { type: 'error', inputs: [], name: 'PermitExpired' },
  { type: 'error', inputs: [], name: 'ReentrancyGuardReentrantCall' },
  {
    type: 'error',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'SafeERC20FailedOperation',
  },
  { type: 'error', inputs: [], name: 'TotalSupplyOverflow' },
] as const

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// AMMRouter
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export const ammRouterAbi = [
  {
    type: 'constructor',
    inputs: [{ name: 'factory_', internalType: 'address', type: 'address' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'tokenA', internalType: 'address', type: 'address' },
      { name: 'tokenB', internalType: 'address', type: 'address' },
      { name: 'amountADesired', internalType: 'uint256', type: 'uint256' },
      { name: 'amountBDesired', internalType: 'uint256', type: 'uint256' },
      { name: 'amountAMin', internalType: 'uint256', type: 'uint256' },
      { name: 'amountBMin', internalType: 'uint256', type: 'uint256' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'addLiquidity',
    outputs: [
      { name: 'amountA', internalType: 'uint256', type: 'uint256' },
      { name: 'amountB', internalType: 'uint256', type: 'uint256' },
      { name: 'liquidity', internalType: 'uint256', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'factory',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'amountOut', internalType: 'uint256', type: 'uint256' },
      { name: 'reserveIn', internalType: 'uint256', type: 'uint256' },
      { name: 'reserveOut', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'getAmountIn',
    outputs: [{ name: 'amountIn', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'pure',
  },
  {
    type: 'function',
    inputs: [
      { name: 'amountIn', internalType: 'uint256', type: 'uint256' },
      { name: 'reserveIn', internalType: 'uint256', type: 'uint256' },
      { name: 'reserveOut', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'getAmountOut',
    outputs: [{ name: 'amountOut', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'pure',
  },
  {
    type: 'function',
    inputs: [
      { name: 'amountOut', internalType: 'uint256', type: 'uint256' },
      { name: 'path', internalType: 'address[]', type: 'address[]' },
    ],
    name: 'getAmountsIn',
    outputs: [
      { name: 'amounts', internalType: 'uint256[]', type: 'uint256[]' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'amountIn', internalType: 'uint256', type: 'uint256' },
      { name: 'path', internalType: 'address[]', type: 'address[]' },
    ],
    name: 'getAmountsOut',
    outputs: [
      { name: 'amounts', internalType: 'uint256[]', type: 'uint256[]' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'pairInitCodeHash',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'amountA', internalType: 'uint256', type: 'uint256' },
      { name: 'reserveA', internalType: 'uint256', type: 'uint256' },
      { name: 'reserveB', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'quote',
    outputs: [{ name: 'amountB', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'pure',
  },
  {
    type: 'function',
    inputs: [
      { name: 'tokenA', internalType: 'address', type: 'address' },
      { name: 'tokenB', internalType: 'address', type: 'address' },
      { name: 'liquidity', internalType: 'uint256', type: 'uint256' },
      { name: 'amountAMin', internalType: 'uint256', type: 'uint256' },
      { name: 'amountBMin', internalType: 'uint256', type: 'uint256' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'removeLiquidity',
    outputs: [
      { name: 'amountA', internalType: 'uint256', type: 'uint256' },
      { name: 'amountB', internalType: 'uint256', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'tokenA', internalType: 'address', type: 'address' },
      { name: 'tokenB', internalType: 'address', type: 'address' },
      { name: 'liquidity', internalType: 'uint256', type: 'uint256' },
      { name: 'amountAMin', internalType: 'uint256', type: 'uint256' },
      { name: 'amountBMin', internalType: 'uint256', type: 'uint256' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'removeLiquiditySupportingFeeOnTransferTokens',
    outputs: [
      { name: 'amountA', internalType: 'uint256', type: 'uint256' },
      { name: 'amountB', internalType: 'uint256', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'tokenA', internalType: 'address', type: 'address' },
      { name: 'tokenB', internalType: 'address', type: 'address' },
      { name: 'liquidity', internalType: 'uint256', type: 'uint256' },
      { name: 'amountAMin', internalType: 'uint256', type: 'uint256' },
      { name: 'amountBMin', internalType: 'uint256', type: 'uint256' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
      { name: 'approveMax', internalType: 'bool', type: 'bool' },
      { name: 'v', internalType: 'uint8', type: 'uint8' },
      { name: 'r', internalType: 'bytes32', type: 'bytes32' },
      { name: 's', internalType: 'bytes32', type: 'bytes32' },
    ],
    name: 'removeLiquidityWithPermit',
    outputs: [
      { name: 'amountA', internalType: 'uint256', type: 'uint256' },
      { name: 'amountB', internalType: 'uint256', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'amountIn', internalType: 'uint256', type: 'uint256' },
      { name: 'amountOutMin', internalType: 'uint256', type: 'uint256' },
      { name: 'path', internalType: 'address[]', type: 'address[]' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'swapExactTokensForTokens',
    outputs: [
      { name: 'amounts', internalType: 'uint256[]', type: 'uint256[]' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'amountIn', internalType: 'uint256', type: 'uint256' },
      { name: 'amountOutMin', internalType: 'uint256', type: 'uint256' },
      { name: 'path', internalType: 'address[]', type: 'address[]' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'swapExactTokensForTokensSupportingFeeOnTransferTokens',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'amountOut', internalType: 'uint256', type: 'uint256' },
      { name: 'amountInMax', internalType: 'uint256', type: 'uint256' },
      { name: 'path', internalType: 'address[]', type: 'address[]' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'swapTokensForExactTokens',
    outputs: [
      { name: 'amounts', internalType: 'uint256[]', type: 'uint256[]' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'error',
    inputs: [
      { name: 'amountIn', internalType: 'uint256', type: 'uint256' },
      { name: 'amountInMax', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'ExcessiveInputAmount',
  },
  {
    type: 'error',
    inputs: [
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
      { name: 'timestamp', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'Expired',
  },
  {
    type: 'error',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'IdenticalAddresses',
  },
  {
    type: 'error',
    inputs: [
      { name: 'amountA', internalType: 'uint256', type: 'uint256' },
      { name: 'amountAMin', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InsufficientAAmount',
  },
  { type: 'error', inputs: [], name: 'InsufficientAmount' },
  {
    type: 'error',
    inputs: [
      { name: 'amountB', internalType: 'uint256', type: 'uint256' },
      { name: 'amountBMin', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InsufficientBAmount',
  },
  { type: 'error', inputs: [], name: 'InsufficientInputAmount' },
  {
    type: 'error',
    inputs: [
      { name: 'reserveIn', internalType: 'uint256', type: 'uint256' },
      { name: 'reserveOut', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InsufficientLiquidity',
  },
  {
    type: 'error',
    inputs: [
      { name: 'amountOut', internalType: 'uint256', type: 'uint256' },
      { name: 'amountOutMin', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InsufficientOutputAmount',
  },
  { type: 'error', inputs: [], name: 'InsufficientOutputAmount' },
  {
    type: 'error',
    inputs: [{ name: 'length', internalType: 'uint256', type: 'uint256' }],
    name: 'InvalidPath',
  },
  { type: 'error', inputs: [], name: 'InvalidRecipient' },
  {
    type: 'error',
    inputs: [
      { name: 'tokenA', internalType: 'address', type: 'address' },
      { name: 'tokenB', internalType: 'address', type: 'address' },
    ],
    name: 'PairNotFound',
  },
  {
    type: 'error',
    inputs: [
      { name: 'allowance', internalType: 'uint256', type: 'uint256' },
      { name: 'liquidity', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'PermitFailed',
  },
  {
    type: 'error',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'SafeERC20FailedOperation',
  },
  { type: 'error', inputs: [], name: 'ZeroAddress' },
] as const

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// React
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammFactoryAbi}__
 */
export const useReadAmmFactory = /*#__PURE__*/ createUseReadContract({
  abi: ammFactoryAbi,
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"PAIR_INIT_CODE_HASH"`
 */
export const useReadAmmFactoryPairInitCodeHash =
  /*#__PURE__*/ createUseReadContract({
    abi: ammFactoryAbi,
    functionName: 'PAIR_INIT_CODE_HASH',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"allPairs"`
 */
export const useReadAmmFactoryAllPairs = /*#__PURE__*/ createUseReadContract({
  abi: ammFactoryAbi,
  functionName: 'allPairs',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"allPairsLength"`
 */
export const useReadAmmFactoryAllPairsLength =
  /*#__PURE__*/ createUseReadContract({
    abi: ammFactoryAbi,
    functionName: 'allPairsLength',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"feeTo"`
 */
export const useReadAmmFactoryFeeTo = /*#__PURE__*/ createUseReadContract({
  abi: ammFactoryAbi,
  functionName: 'feeTo',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"getPair"`
 */
export const useReadAmmFactoryGetPair = /*#__PURE__*/ createUseReadContract({
  abi: ammFactoryAbi,
  functionName: 'getPair',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"owner"`
 */
export const useReadAmmFactoryOwner = /*#__PURE__*/ createUseReadContract({
  abi: ammFactoryAbi,
  functionName: 'owner',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"parameters"`
 */
export const useReadAmmFactoryParameters = /*#__PURE__*/ createUseReadContract({
  abi: ammFactoryAbi,
  functionName: 'parameters',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"pendingOwner"`
 */
export const useReadAmmFactoryPendingOwner =
  /*#__PURE__*/ createUseReadContract({
    abi: ammFactoryAbi,
    functionName: 'pendingOwner',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammFactoryAbi}__
 */
export const useWriteAmmFactory = /*#__PURE__*/ createUseWriteContract({
  abi: ammFactoryAbi,
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"acceptOwnership"`
 */
export const useWriteAmmFactoryAcceptOwnership =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammFactoryAbi,
    functionName: 'acceptOwnership',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"createPair"`
 */
export const useWriteAmmFactoryCreatePair =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammFactoryAbi,
    functionName: 'createPair',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"renounceOwnership"`
 */
export const useWriteAmmFactoryRenounceOwnership =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammFactoryAbi,
    functionName: 'renounceOwnership',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"setFeeTo"`
 */
export const useWriteAmmFactorySetFeeTo = /*#__PURE__*/ createUseWriteContract({
  abi: ammFactoryAbi,
  functionName: 'setFeeTo',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"transferOwnership"`
 */
export const useWriteAmmFactoryTransferOwnership =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammFactoryAbi,
    functionName: 'transferOwnership',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammFactoryAbi}__
 */
export const useSimulateAmmFactory = /*#__PURE__*/ createUseSimulateContract({
  abi: ammFactoryAbi,
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"acceptOwnership"`
 */
export const useSimulateAmmFactoryAcceptOwnership =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammFactoryAbi,
    functionName: 'acceptOwnership',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"createPair"`
 */
export const useSimulateAmmFactoryCreatePair =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammFactoryAbi,
    functionName: 'createPair',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"renounceOwnership"`
 */
export const useSimulateAmmFactoryRenounceOwnership =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammFactoryAbi,
    functionName: 'renounceOwnership',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"setFeeTo"`
 */
export const useSimulateAmmFactorySetFeeTo =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammFactoryAbi,
    functionName: 'setFeeTo',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammFactoryAbi}__ and `functionName` set to `"transferOwnership"`
 */
export const useSimulateAmmFactoryTransferOwnership =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammFactoryAbi,
    functionName: 'transferOwnership',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammFactoryAbi}__
 */
export const useWatchAmmFactoryEvent =
  /*#__PURE__*/ createUseWatchContractEvent({ abi: ammFactoryAbi })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammFactoryAbi}__ and `eventName` set to `"FeeToUpdated"`
 */
export const useWatchAmmFactoryFeeToUpdatedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammFactoryAbi,
    eventName: 'FeeToUpdated',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammFactoryAbi}__ and `eventName` set to `"OwnershipTransferStarted"`
 */
export const useWatchAmmFactoryOwnershipTransferStartedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammFactoryAbi,
    eventName: 'OwnershipTransferStarted',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammFactoryAbi}__ and `eventName` set to `"OwnershipTransferred"`
 */
export const useWatchAmmFactoryOwnershipTransferredEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammFactoryAbi,
    eventName: 'OwnershipTransferred',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammFactoryAbi}__ and `eventName` set to `"PairCreated"`
 */
export const useWatchAmmFactoryPairCreatedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammFactoryAbi,
    eventName: 'PairCreated',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__
 */
export const useReadAmmPair = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"CALLBACK_SUCCESS"`
 */
export const useReadAmmPairCallbackSuccess =
  /*#__PURE__*/ createUseReadContract({
    abi: ammPairAbi,
    functionName: 'CALLBACK_SUCCESS',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"DOMAIN_SEPARATOR"`
 */
export const useReadAmmPairDomainSeparator =
  /*#__PURE__*/ createUseReadContract({
    abi: ammPairAbi,
    functionName: 'DOMAIN_SEPARATOR',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"MINIMUM_LIQUIDITY"`
 */
export const useReadAmmPairMinimumLiquidity =
  /*#__PURE__*/ createUseReadContract({
    abi: ammPairAbi,
    functionName: 'MINIMUM_LIQUIDITY',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"allowance"`
 */
export const useReadAmmPairAllowance = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'allowance',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"balanceOf"`
 */
export const useReadAmmPairBalanceOf = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'balanceOf',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"decimals"`
 */
export const useReadAmmPairDecimals = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'decimals',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"factory"`
 */
export const useReadAmmPairFactory = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'factory',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"getReserves"`
 */
export const useReadAmmPairGetReserves = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'getReserves',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"isLocked"`
 */
export const useReadAmmPairIsLocked = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'isLocked',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"kLast"`
 */
export const useReadAmmPairKLast = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'kLast',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"name"`
 */
export const useReadAmmPairName = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'name',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"nonces"`
 */
export const useReadAmmPairNonces = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'nonces',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"price0CumulativeLast"`
 */
export const useReadAmmPairPrice0CumulativeLast =
  /*#__PURE__*/ createUseReadContract({
    abi: ammPairAbi,
    functionName: 'price0CumulativeLast',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"price1CumulativeLast"`
 */
export const useReadAmmPairPrice1CumulativeLast =
  /*#__PURE__*/ createUseReadContract({
    abi: ammPairAbi,
    functionName: 'price1CumulativeLast',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"symbol"`
 */
export const useReadAmmPairSymbol = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'symbol',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"token0"`
 */
export const useReadAmmPairToken0 = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'token0',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"token1"`
 */
export const useReadAmmPairToken1 = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'token1',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"totalSupply"`
 */
export const useReadAmmPairTotalSupply = /*#__PURE__*/ createUseReadContract({
  abi: ammPairAbi,
  functionName: 'totalSupply',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__
 */
export const useWriteAmmPair = /*#__PURE__*/ createUseWriteContract({
  abi: ammPairAbi,
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"approve"`
 */
export const useWriteAmmPairApprove = /*#__PURE__*/ createUseWriteContract({
  abi: ammPairAbi,
  functionName: 'approve',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"burn"`
 */
export const useWriteAmmPairBurn = /*#__PURE__*/ createUseWriteContract({
  abi: ammPairAbi,
  functionName: 'burn',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"mint"`
 */
export const useWriteAmmPairMint = /*#__PURE__*/ createUseWriteContract({
  abi: ammPairAbi,
  functionName: 'mint',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"permit"`
 */
export const useWriteAmmPairPermit = /*#__PURE__*/ createUseWriteContract({
  abi: ammPairAbi,
  functionName: 'permit',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"skim"`
 */
export const useWriteAmmPairSkim = /*#__PURE__*/ createUseWriteContract({
  abi: ammPairAbi,
  functionName: 'skim',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"swap"`
 */
export const useWriteAmmPairSwap = /*#__PURE__*/ createUseWriteContract({
  abi: ammPairAbi,
  functionName: 'swap',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"sync"`
 */
export const useWriteAmmPairSync = /*#__PURE__*/ createUseWriteContract({
  abi: ammPairAbi,
  functionName: 'sync',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"transfer"`
 */
export const useWriteAmmPairTransfer = /*#__PURE__*/ createUseWriteContract({
  abi: ammPairAbi,
  functionName: 'transfer',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"transferFrom"`
 */
export const useWriteAmmPairTransferFrom = /*#__PURE__*/ createUseWriteContract(
  { abi: ammPairAbi, functionName: 'transferFrom' },
)

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__
 */
export const useSimulateAmmPair = /*#__PURE__*/ createUseSimulateContract({
  abi: ammPairAbi,
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"approve"`
 */
export const useSimulateAmmPairApprove =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammPairAbi,
    functionName: 'approve',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"burn"`
 */
export const useSimulateAmmPairBurn = /*#__PURE__*/ createUseSimulateContract({
  abi: ammPairAbi,
  functionName: 'burn',
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"mint"`
 */
export const useSimulateAmmPairMint = /*#__PURE__*/ createUseSimulateContract({
  abi: ammPairAbi,
  functionName: 'mint',
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"permit"`
 */
export const useSimulateAmmPairPermit = /*#__PURE__*/ createUseSimulateContract(
  { abi: ammPairAbi, functionName: 'permit' },
)

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"skim"`
 */
export const useSimulateAmmPairSkim = /*#__PURE__*/ createUseSimulateContract({
  abi: ammPairAbi,
  functionName: 'skim',
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"swap"`
 */
export const useSimulateAmmPairSwap = /*#__PURE__*/ createUseSimulateContract({
  abi: ammPairAbi,
  functionName: 'swap',
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"sync"`
 */
export const useSimulateAmmPairSync = /*#__PURE__*/ createUseSimulateContract({
  abi: ammPairAbi,
  functionName: 'sync',
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"transfer"`
 */
export const useSimulateAmmPairTransfer =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammPairAbi,
    functionName: 'transfer',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammPairAbi}__ and `functionName` set to `"transferFrom"`
 */
export const useSimulateAmmPairTransferFrom =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammPairAbi,
    functionName: 'transferFrom',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammPairAbi}__
 */
export const useWatchAmmPairEvent = /*#__PURE__*/ createUseWatchContractEvent({
  abi: ammPairAbi,
})

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammPairAbi}__ and `eventName` set to `"Approval"`
 */
export const useWatchAmmPairApprovalEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammPairAbi,
    eventName: 'Approval',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammPairAbi}__ and `eventName` set to `"Burn"`
 */
export const useWatchAmmPairBurnEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammPairAbi,
    eventName: 'Burn',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammPairAbi}__ and `eventName` set to `"Mint"`
 */
export const useWatchAmmPairMintEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammPairAbi,
    eventName: 'Mint',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammPairAbi}__ and `eventName` set to `"Swap"`
 */
export const useWatchAmmPairSwapEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammPairAbi,
    eventName: 'Swap',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammPairAbi}__ and `eventName` set to `"Sync"`
 */
export const useWatchAmmPairSyncEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammPairAbi,
    eventName: 'Sync',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link ammPairAbi}__ and `eventName` set to `"Transfer"`
 */
export const useWatchAmmPairTransferEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: ammPairAbi,
    eventName: 'Transfer',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammRouterAbi}__
 */
export const useReadAmmRouter = /*#__PURE__*/ createUseReadContract({
  abi: ammRouterAbi,
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"factory"`
 */
export const useReadAmmRouterFactory = /*#__PURE__*/ createUseReadContract({
  abi: ammRouterAbi,
  functionName: 'factory',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"getAmountIn"`
 */
export const useReadAmmRouterGetAmountIn = /*#__PURE__*/ createUseReadContract({
  abi: ammRouterAbi,
  functionName: 'getAmountIn',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"getAmountOut"`
 */
export const useReadAmmRouterGetAmountOut = /*#__PURE__*/ createUseReadContract(
  { abi: ammRouterAbi, functionName: 'getAmountOut' },
)

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"getAmountsIn"`
 */
export const useReadAmmRouterGetAmountsIn = /*#__PURE__*/ createUseReadContract(
  { abi: ammRouterAbi, functionName: 'getAmountsIn' },
)

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"getAmountsOut"`
 */
export const useReadAmmRouterGetAmountsOut =
  /*#__PURE__*/ createUseReadContract({
    abi: ammRouterAbi,
    functionName: 'getAmountsOut',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"pairInitCodeHash"`
 */
export const useReadAmmRouterPairInitCodeHash =
  /*#__PURE__*/ createUseReadContract({
    abi: ammRouterAbi,
    functionName: 'pairInitCodeHash',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"quote"`
 */
export const useReadAmmRouterQuote = /*#__PURE__*/ createUseReadContract({
  abi: ammRouterAbi,
  functionName: 'quote',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammRouterAbi}__
 */
export const useWriteAmmRouter = /*#__PURE__*/ createUseWriteContract({
  abi: ammRouterAbi,
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"addLiquidity"`
 */
export const useWriteAmmRouterAddLiquidity =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammRouterAbi,
    functionName: 'addLiquidity',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"removeLiquidity"`
 */
export const useWriteAmmRouterRemoveLiquidity =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammRouterAbi,
    functionName: 'removeLiquidity',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"removeLiquiditySupportingFeeOnTransferTokens"`
 */
export const useWriteAmmRouterRemoveLiquiditySupportingFeeOnTransferTokens =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammRouterAbi,
    functionName: 'removeLiquiditySupportingFeeOnTransferTokens',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"removeLiquidityWithPermit"`
 */
export const useWriteAmmRouterRemoveLiquidityWithPermit =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammRouterAbi,
    functionName: 'removeLiquidityWithPermit',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"swapExactTokensForTokens"`
 */
export const useWriteAmmRouterSwapExactTokensForTokens =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammRouterAbi,
    functionName: 'swapExactTokensForTokens',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"swapExactTokensForTokensSupportingFeeOnTransferTokens"`
 */
export const useWriteAmmRouterSwapExactTokensForTokensSupportingFeeOnTransferTokens =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammRouterAbi,
    functionName: 'swapExactTokensForTokensSupportingFeeOnTransferTokens',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"swapTokensForExactTokens"`
 */
export const useWriteAmmRouterSwapTokensForExactTokens =
  /*#__PURE__*/ createUseWriteContract({
    abi: ammRouterAbi,
    functionName: 'swapTokensForExactTokens',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammRouterAbi}__
 */
export const useSimulateAmmRouter = /*#__PURE__*/ createUseSimulateContract({
  abi: ammRouterAbi,
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"addLiquidity"`
 */
export const useSimulateAmmRouterAddLiquidity =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammRouterAbi,
    functionName: 'addLiquidity',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"removeLiquidity"`
 */
export const useSimulateAmmRouterRemoveLiquidity =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammRouterAbi,
    functionName: 'removeLiquidity',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"removeLiquiditySupportingFeeOnTransferTokens"`
 */
export const useSimulateAmmRouterRemoveLiquiditySupportingFeeOnTransferTokens =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammRouterAbi,
    functionName: 'removeLiquiditySupportingFeeOnTransferTokens',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"removeLiquidityWithPermit"`
 */
export const useSimulateAmmRouterRemoveLiquidityWithPermit =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammRouterAbi,
    functionName: 'removeLiquidityWithPermit',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"swapExactTokensForTokens"`
 */
export const useSimulateAmmRouterSwapExactTokensForTokens =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammRouterAbi,
    functionName: 'swapExactTokensForTokens',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"swapExactTokensForTokensSupportingFeeOnTransferTokens"`
 */
export const useSimulateAmmRouterSwapExactTokensForTokensSupportingFeeOnTransferTokens =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammRouterAbi,
    functionName: 'swapExactTokensForTokensSupportingFeeOnTransferTokens',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link ammRouterAbi}__ and `functionName` set to `"swapTokensForExactTokens"`
 */
export const useSimulateAmmRouterSwapTokensForExactTokens =
  /*#__PURE__*/ createUseSimulateContract({
    abi: ammRouterAbi,
    functionName: 'swapTokensForExactTokens',
  })
