// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IV2Factory, IV2Pair, IV2Router} from "./interfaces/IV2.sol";
import {IIgnisMinter} from "./interfaces/IIgnisMinter.sol";

/// @notice Minter-issued Ignis with a hard supply cap and 2% fees on non-exempt trades.
contract IgnisToken is ERC20, Ownable2Step {
    uint256 public constant MAX_SUPPLY = 44_000_000_000_000 ether;
    uint256 public constant BPS = 10_000;
    uint256 public constant BURN_FEE_BPS = 100;
    uint256 public constant MINTER_FEE_BPS = 100;
    uint256 public constant LP_BURN_BPS = 1;
    uint256 public constant LP_MIN_CIRCULATING_BPS = 1_500;
    uint256 public constant LP_FAST_CIRCULATING_BPS = 4_000;
    uint256 public constant LP_BURN_INTERVAL = 3 minutes;
    uint256 public constant LP_FAST_BURN_INTERVAL = 1 minutes;
    uint256 public constant LP_BURN_DURATION = 15 days;
    address public constant DEAD = address(0xdead);

    address public immutable wbnb;
    address public immutable pair;
    IV2Router public immutable router;
    uint256 public immutable mintedAt;
    uint256 public lpBurnEndsAt = type(uint256).max;
    uint256 public lastLpBurnAt;
    bool public tradingOpen;
    address public minter;
    uint256 public mintingCompletedAt;
    mapping(address => bool) public isWhitelisted;

    event TradingOpened();
    event TaxCollected(address indexed from, address indexed to, uint256 burned, uint256 taxTokens);
    event LpBurned(uint256 amount, uint256 pairBalanceAfter, uint256 circulatingAfter);
    event MinterBound(address indexed minter);
    event MintingCompleted(uint256 completedAt, uint256 lpBurnEndsAt);
    event WhitelistUpdated(address indexed account, bool enabled);

    error InvalidConfig();
    error TradingClosed();
    error AlreadyOpen();
    error OnlySelf();
    error OnlyMinter();
    error SupplyCapExceeded();

    constructor(address admin, address router_) ERC20("IGNIS", "IGNIS") Ownable(admin) {
        if (router_.code.length == 0) revert InvalidConfig();
        router = IV2Router(router_);
        address wrapped = IV2Router(router_).WETH();
        if (wrapped.code.length == 0) revert InvalidConfig();
        wbnb = wrapped;
        address factory = IV2Router(router_).factory();
        if (factory.code.length == 0) revert InvalidConfig();
        pair = IV2Factory(factory).createPair(address(this), wrapped);
        if (pair.code.length == 0) revert InvalidConfig();
        mintedAt = block.timestamp;
        lastLpBurnAt = block.timestamp;
    }

    /// @notice Only the bound Mint proxy can issue tokens; dead-address transfers never free cap.
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter || minter == address(0)) revert OnlyMinter();
        if (amount > MAX_SUPPLY - totalSupply()) revert SupplyCapExceeded();
        _mint(to, amount);
    }

    /// @notice Seed the pool before opening; only the bound Minter may open trading.
    function openTrading() external {
        if (minter == address(0) || msg.sender != minter) revert InvalidConfig();
        if (tradingOpen) revert AlreadyOpen();
        (uint112 r0, uint112 r1,) = IV2Pair(pair).getReserves();
        if (r0 == 0 || r1 == 0) revert InvalidConfig();
        tradingOpen = true;
        emit TradingOpened();
    }

    function bindMinter(address minter_) external onlyOwner {
        if (
            tradingOpen || minter != address(0) || minter_.code.length == 0
                || IIgnisMinter(minter_).token() != address(this)
        ) revert InvalidConfig();
        minter = minter_;
        _setWhitelist(minter_, true);
        emit MinterBound(minter_);
    }

    /// @notice Either whitelisted endpoint permits pre-opening transfers and exempts trade fees.
    function setWhitelist(address account, bool enabled) external onlyOwner {
        _setWhitelist(account, enabled);
    }

    function setWhitelistBatch(address[] calldata accounts, bool enabled) external onlyOwner {
        for (uint256 i; i < accounts.length; ++i) {
            _setWhitelist(accounts[i], enabled);
        }
    }

    function _setWhitelist(address account, bool enabled) private {
        if (account == address(0) || account == DEAD || account == address(this) || account == pair) {
            revert InvalidConfig();
        }
        isWhitelisted[account] = enabled;
        emit WhitelistUpdated(account, enabled);
    }

    function notifyMintingCompleted() external {
        if (msg.sender != minter || minter == address(0) || mintingCompletedAt != 0) revert InvalidConfig();
        mintingCompletedAt = block.timestamp;
        lpBurnEndsAt = block.timestamp + LP_BURN_DURATION;
        emit MintingCompleted(block.timestamp, lpBurnEndsAt);
    }

    /// @notice Total supply minus the dead-address balance, including all Minter and LP balances.
    function circulatingSupply() public view returns (uint256) {
        return totalSupply() - balanceOf(DEAD);
    }

    /// @notice Current interval by pool/circulating ratio; zero means paused below 15%.
    function lpBurnInterval() public view returns (uint256) {
        uint256 poolBalance = balanceOf(pair);
        uint256 circulating = circulatingSupply();
        if (poolBalance == 0 || poolBalance * BPS < circulating * LP_MIN_CIRCULATING_BPS) return 0;
        return poolBalance * BPS >= circulating * LP_FAST_CIRCULATING_BPS
            ? LP_FAST_BURN_INTERVAL
            : LP_BURN_INTERVAL;
    }

    function lpBurnEligible() public view returns (bool) {
        if (!tradingOpen || block.timestamp >= lpBurnEndsAt) return false;
        uint256 interval = lpBurnInterval();
        return interval != 0 && block.timestamp >= lastLpBurnAt + interval;
    }

    /// @notice Permissionless keeper entry. At most one 0.01% burn; missed intervals are not replayed.
    /// @dev The external self-call rolls back both burn and timestamp if the pair is locked.
    function burnLp() public returns (uint256 amount) {
        if (!lpBurnEligible() || !_pairSettled()) return 0;
        try this.executeLpBurn() returns (uint256 burned) {
            return burned;
        } catch {
            return 0;
        }
    }

    function executeLpBurn() external returns (uint256 amount) {
        if (msg.sender != address(this)) revert OnlySelf();
        amount = balanceOf(pair) * LP_BURN_BPS / BPS;
        if (amount == 0) return 0;
        lastLpBurnAt = block.timestamp;
        super._update(pair, DEAD, amount);
        IV2Pair(pair).sync();
        emit LpBurned(amount, balanceOf(pair), circulatingSupply());
    }

    /// @dev Never sync across pending swap/liquidity inputs in either pool asset.
    function _pairSettled() private view returns (bool) {
        (uint112 r0, uint112 r1,) = IV2Pair(pair).getReserves();
        bool ignisFirst = IV2Pair(pair).token0() == address(this);
        return balanceOf(pair) == (ignisFirst ? r0 : r1) && IERC20(wbnb).balanceOf(pair) == (ignisFirst ? r1 : r0);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0)) {
            super._update(from, to, value);
            return;
        }
        // Bound mint settlement is exempt: user allocation, bootstrap, LP funding and fee conversion.
        if (minter != address(0) && (from == minter || to == minter)) {
            super._update(from, to, value);
            return;
        }
        bool whitelisted = isWhitelisted[from] || isWhitelisted[to];
        if (!tradingOpen) {
            if (!whitelisted) revert TradingClosed();
            super._update(from, to, value);
            return;
        }

        // Pair-origin transfers occur under the V2 swap/burn lock. Do no external work there.
        if (value != 0 && from != pair) {
            burnLp();
        }

        if (!whitelisted && (from == pair || to == pair) && value != 0) {
            uint256 burned = value * BURN_FEE_BPS / BPS;
            uint256 taxTokens = value * MINTER_FEE_BPS / BPS;
            super._update(from, DEAD, burned);
            super._update(from, minter, taxTokens);
            super._update(from, to, value - burned - taxTokens);
            emit TaxCollected(from, to, burned, taxTokens);
        } else {
            super._update(from, to, value);
        }
    }
}
