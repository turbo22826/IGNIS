// SPDX-License-Identifier: MIT
//0x0e2f75871c07a2bf879E0916B4d017fdaFCe10Ee
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IgnisToken} from "./IgnisToken.sol";
import {IV2Pair, IV2Router} from "./interfaces/IV2.sol";
import {MintPricing} from "./libraries/MintPricing.sol";
import {MintFunds} from "./libraries/MintFunds.sol";
import {IIgnisDapp} from "./interfaces/IIgnisDapp.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IAgentIdRegistry} from "./interfaces/IAgentIdRegistry.sol";

/// @notice UUPS gradual issuance, paid mint settlement and independent trade-tax conversion.
contract IgnisMinter is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SHARES = 4_000_000;
    uint256 public constant GENESIS_SHARES = 12_000;
    uint256 public constant WALLET_LIMIT = 10;
    uint256 public constant TEN_SHARE_BUNDLE = 10;
    uint256 public constant TEN_SHARE_PRICE = 20;
    address public constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    uint256 public constant MAX_TOKENS_PER_SHARE = 20_000_000 ether;
    uint256 public constant GENESIS_TOKENS_PER_SHARE = 10_000_000 ether;
    uint256 public constant OPENING_LP_TOKENS = 100_000_000_000 ether;
    uint256 public constant MIN_QUOTE_BPS = 9_500;
    uint256 public constant MAX_NATIVE_PREMIUM_BPS = 500;
    address public constant TREASURY = 0xC03B0b9005Bd144FEe3469CB56ef5c1e8E58c008;
    address public constant TAX_RECIPIENT = 0xdFcd8556527b6c1e27588166B6F1A471DFa7628c;
    address public constant WITHDRAWAL_AUTHORITY = 0x3175137FF59499a2f09C9C88d548DAe1D4b45A21;
    address public constant lpRecipient = 0x000000000000000000000000000000000000dEaD;
    bytes32 public constant STORAGE_LAYOUT_ID = keccak256("ignis.minter.fresh.v1");

    struct Config {
        address admin;
        address token;
        address usdt;
        uint256 swapThreshold;
    }

    struct Limits {
        uint256 maxUsdt;
        uint256 minUserTokens;
        uint256 minBuyTokens;
        uint256 minWbnb;
        uint256 minLiquidity;
        uint256 deadline;
    }

    IgnisToken public token;
    IERC20 public usdt;
    IERC20 public wbnb;
    IV2Router public router;
    address public pair;
    uint256 public usdtUnit;
    uint256 public swapThreshold;
    uint256 public totalMinted;
    uint256 public totalPaid;
    uint256 public totalUserTokens;
    uint256 public pendingGenesisUsdt;
    uint256 public totalTaxUsdt;
    uint256 public totalLpMinted;
    mapping(address => uint256) public walletMinted;
    bool public poolOpen;
    bool public finished;
    address public dapp;
    IAggregatorV3 public bnbUsdFeed;
    uint32 public bnbPriceMaxAge;
    IAggregatorV3 public usdtUsdFeed;
    uint32 public usdtPriceMaxAge;

    event Minted(address indexed wallet, uint256 shares, uint256 costUsdt, uint256 userTokens);
    event PoolOpened(uint256 budgetUsdt, uint256 wbnbIn, uint256 ignisIn, uint256 liquidity);
    event LiquidityAdded(uint256 buyUsdt, uint256 liquidityUsdt, uint256 ignisIn, uint256 wbnbIn, uint256 liquidity);
    event TaxProcessed(uint256 tokens, uint256 usdtOut);
    event MintingFinished(uint256 shares, uint256 userTokens);
    event DappConfigured(address indexed dapp);
    event NativePayment(address indexed wallet, uint256 bnbSpent, uint256 bnbRefunded, uint256 costUsdt);
    event PriceFeedsConfigured(address indexed bnbUsd, address indexed usdtUsd, uint32 bnbMaxAge, uint32 usdtMaxAge);

    error InvalidConfig();
    error InvalidShares();
    error WalletLimitExceeded();
    error CrossGenesisBoundary();
    error MintStopped();
    error NotBound();
    error Slippage();
    error InsufficientMintableSupply();
    error NoTaxToProcess();
    error InvalidTaxAmount();
    error DappNotConfigured();
    error ReferrerMismatch();
    error InvalidNativePayment();
    error NativeRefundFailed();
    error OnlyRouter();
    error InvalidOraclePrice();
    error StaleOraclePrice();
    error NativePriceDeviation();
    error AgentWalletRequired();
    error UnauthorizedWithdrawal();
    error InvalidWithdrawal();

    modifier onlyAgentWallet() {
        (, bool ok) = agentOf(msg.sender);
        if (!ok) revert AgentWalletRequired();
        _;
    }

    function agentOf(address wallet) public view returns (uint256 id, bool ok) {
        IAgentIdRegistry registrar = IAgentIdRegistry(AGENT_ID_REGISTRY);
        if (wallet == address(0) || address(registrar).code.length == 0) return (0, false);
        try registrar.handleOf(wallet) returns (string memory handle) {
            if (bytes(handle).length == 0) return (0, false);
            id = uint256(keccak256(bytes(handle)));
            try registrar.ownerOf(id) returns (address owner) {
                ok = owner == wallet;
            } catch {}
        } catch {}
    }

    function isBinanceAgentWallet(address wallet) external view returns (bool) {
        (, bool ok) = agentOf(wallet);
        return ok;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(Config calldata c) external initializer {
        if (c.token.code.length == 0 || c.usdt.code.length == 0 || c.swapThreshold == 0) revert InvalidConfig();
        __Ownable_init(c.admin);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        _pause();
        token = IgnisToken(c.token);
        usdt = IERC20(c.usdt);
        uint8 decimals_ = IERC20Metadata(c.usdt).decimals();
        if (decimals_ < 2 || decimals_ > 18 || token.decimals() != 18 || token.tradingOpen()) revert InvalidConfig();
        usdtUnit = 10 ** decimals_;
        router = token.router();
        if (c.usdt == token.wbnb() || c.usdt == c.token || c.swapThreshold > token.MAX_SUPPLY() / 10) {
            revert InvalidConfig();
        }
        wbnb = IERC20(token.wbnb());
        pair = token.pair();
        swapThreshold = c.swapThreshold;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Pause all paid mint entry points without affecting tax settlement.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Transfer ERC20, or native BNB when asset is the zero address.
    /// @dev Authority is fixed independently of owner and remains usable while paused.
    ///      Withdrawing reserved genesis USDT can leave insufficient funds to open the pool;
    ///      this operation does not reduce pendingGenesisUsdt or other mint accounting.
    function withdraw(address asset, address recipient, uint256 amount) external nonReentrant {
        if (msg.sender != WITHDRAWAL_AUTHORITY) revert UnauthorizedWithdrawal();
        if (recipient == address(0) || recipient == address(this) || amount == 0) revert InvalidWithdrawal();
        if (asset == address(0)) {
            Address.sendValue(payable(recipient), amount);
        } else {
            IERC20(asset).safeTransfer(recipient, amount);
        }
    }

    /// @notice Configure Chainlink proxy addresses; an upgraded proxy cannot accept BNB until configured.
    function configurePriceFeeds(address bnbUsd, address usdtUsd, uint32 bnbMaxAge, uint32 usdtMaxAge)
        external
        onlyOwner
    {
        if (
            bnbUsd == usdtUsd || bnbUsd.code.length == 0 || usdtUsd.code.length == 0 || bnbMaxAge == 0
                || usdtMaxAge == 0 || bnbMaxAge > 1 days || usdtMaxAge > 1 days
        ) revert InvalidConfig();
        _readPrice(IAggregatorV3(bnbUsd), bnbMaxAge);
        _readPrice(IAggregatorV3(usdtUsd), usdtMaxAge);
        bnbUsdFeed = IAggregatorV3(bnbUsd);
        usdtUsdFeed = IAggregatorV3(usdtUsd);
        bnbPriceMaxAge = bnbMaxAge;
        usdtPriceMaxAge = usdtMaxAge;
        emit PriceFeedsConfigured(bnbUsd, usdtUsd, bnbMaxAge, usdtMaxAge);
    }

    /// @notice Chainlink cross-rate in the payment token's decimals, per one native BNB.
    function bnbPriceUsdt() external view returns (uint256) {
        return Math.mulDiv(_readPrice(bnbUsdFeed, bnbPriceMaxAge), usdtUnit, _readPrice(usdtUsdFeed, usdtPriceMaxAge));
    }

    function _readPrice(IAggregatorV3 feed, uint32 maxAge) private view returns (uint256) {
        if (address(feed) == address(0) || maxAge == 0) revert InvalidConfig();
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (roundId == 0 || answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert InvalidOraclePrice();
        if (block.timestamp - updatedAt > maxAge) revert StaleOraclePrice();
        uint8 decimals_ = feed.decimals();
        if (decimals_ > 18) revert InvalidOraclePrice();
        return Math.mulDiv(uint256(answer), 1 ether, 10 ** decimals_);
    }

    function _quoteNative(uint256 cost) private view returns (uint256) {
        uint256 bnbUsd = _readPrice(bnbUsdFeed, bnbPriceMaxAge);
        uint256 usdtUsd = _readPrice(usdtUsdFeed, usdtPriceMaxAge);
        return Math.mulDiv(cost * (1 ether / usdtUnit), usdtUsd, bnbUsd, Math.Rounding.Ceil);
    }

    /// @notice Configure the unified DApp once, before minting starts.
    function configureDapp(address dapp_) external onlyOwner {
        if (
            dapp != address(0) || totalMinted != 0 || dapp_.code.length == 0
                || IIgnisDapp(dapp_).minter() != address(this) || IIgnisDapp(dapp_).usdt() != address(usdt)
        ) {
            revert InvalidConfig();
        }
        dapp = dapp_;
        emit DappConfigured(dapp_);
    }

    /// @notice Lifetime paid quota: base 10 + one per qualified invite + one social reward.
    function walletQuota(address wallet) public view returns (uint256 quota) {
        quota = WALLET_LIMIT;
        if (dapp != address(0)) {
            quota += IIgnisDapp(dapp).effectiveInvites(wallet);
            if (IIgnisDapp(dapp).completed(wallet)) quota += 1;
        }
    }

    /// @notice Minting N shares consumes N of the remaining quota; rewards never reset prior usage.
    function remainingWalletQuota(address wallet) public view returns (uint256) {
        return walletQuota(wallet) - walletMinted[wallet];
    }

    function pricePerShare(uint256 shareIndex) public view returns (uint256) {
        return MintPricing.priceCents(shareIndex) * usdtUnit / 100;
    }

    /// @notice Genesis issues 10,000,000 IGNIS per share; post-opening allocation is capped at 20,000,000.
    /// @dev The full-payment DEX quote can reduce, but never increase, this allocation ceiling.
    function quoteMint(uint256 shares) public view returns (uint256 cost, uint256 userTokens) {
        cost = MintPricing.quoteCents(totalMinted, shares) * usdtUnit / 100;
        userTokens = _quoteMintAllocation(shares, cost);
    }

    /// @notice Fixed-price USDT bundle, available to any wallet: ten shares for twenty USDT.
    function quoteMintTenShares() public view returns (uint256 cost, uint256 userTokens) {
        if (TEN_SHARE_BUNDLE > TOTAL_SHARES - totalMinted) revert InvalidShares();
        cost = TEN_SHARE_PRICE * usdtUnit;
        userTokens = _quoteMintAllocation(TEN_SHARE_BUNDLE, cost);
    }

    function _quoteMintAllocation(uint256 shares, uint256 cost) private view returns (uint256 userTokens) {
        if (totalMinted < GENESIS_SHARES) {
            if (shares > GENESIS_SHARES - totalMinted) revert CrossGenesisBoundary();
            userTokens = shares * GENESIS_TOKENS_PER_SHARE;
        } else {
            userTokens = Math.min(_quote(cost, _path(address(usdt), address(token))), shares * MAX_TOKENS_PER_SHARE);
        }
    }

    /// @notice Chainlink BNB reference, rounded up to wei. Allow settlement fees/slippage in msg.value.
    /// @dev Exact-output settlement is capped at 105% of this reference and at the caller's msg.value.
    function quoteMintWithBNB(uint256 shares)
        external
        view
        returns (uint256 cost, uint256 userTokens, uint256 bnbRequired)
    {
        (cost, userTokens) = quoteMint(shares);
        bnbRequired = _quoteNative(cost);
    }

    function openingReferenceUsdt() public view returns (uint256) {
        return 19_200 * usdtUnit;
    }

    function remainingMintableSupply() public view returns (uint256) {
        return token.MAX_SUPPLY() - token.totalSupply();
    }

    /// @notice Successful settlement returns true; invalid payment, allocation or limits revert atomically.
    function mint(uint256 shares, Limits calldata l)
        external
        whenNotPaused
        nonReentrant
        onlyAgentWallet
        returns (bool success)
    {
        return _mintShares(shares, l, address(0), false, false);
    }

    function mintWithReferrer(uint256 shares, Limits calldata l, address referrer_)
        external
        whenNotPaused
        nonReentrant
        onlyAgentWallet
        returns (bool success)
    {
        return _mintShares(shares, l, referrer_, false, false);
    }

    /// @notice Pays the same USDT-denominated mint cost with native BNB, optionally binding a referrer.
    function mintWithBNB(uint256 shares, Limits calldata l, address referrer_)
        external
        payable
        whenNotPaused
        nonReentrant
        onlyAgentWallet
        returns (bool success)
    {
        if (msg.value == 0) revert InvalidNativePayment();
        success = _mintShares(shares, l, referrer_, true, false);
    }

    /// @dev Router refunds excess native input here. Ordinary native transfers are rejected.
    receive() external payable {
        if (msg.sender != address(router)) revert OnlyRouter();
    }

    function _mintShares(uint256 shares, Limits calldata l, address referrer_, bool nativePayment, bool fixedBundle)
        private
        returns (bool success)
    {
        if (dapp == address(0)) revert DappNotConfigured();
        if (token.minter() != address(this)) revert NotBound();
        if (finished) revert MintStopped();
        if (shares == 0 || shares > TOTAL_SHARES - totalMinted) revert InvalidShares();
        if (shares > remainingWalletQuota(msg.sender)) revert WalletLimitExceeded();
        if (l.deadline < block.timestamp || l.deadline > block.timestamp + 20 minutes) revert Slippage();
        (uint256 cost, uint256 userTokens) = fixedBundle ? quoteMintTenShares() : quoteMint(shares);
        if (cost > l.maxUsdt || userTokens < l.minUserTokens || userTokens == 0) revert Slippage();
        uint256 reserve = poolOpen ? 0 : OPENING_LP_TOKENS;
        if (remainingMintableSupply() < userTokens + reserve) revert InsufficientMintableSupply();

        if (referrer_ != address(0)) {
            address bound = IIgnisDapp(dapp).referrerOf(msg.sender);
            if (bound == address(0)) IIgnisDapp(dapp).bindFor(msg.sender, referrer_);
            else if (bound != referrer_) revert ReferrerMismatch();
        }

        totalMinted += shares;
        walletMinted[msg.sender] += shares;
        totalPaid += cost;
        totalUserTokens += userTokens;
        uint256 nativeSpent = _collectPayment(cost, l.deadline, nativePayment);
        (uint256 buy, uint256 liquidity, uint256 treasury) = MintFunds.split(cost);
        usdt.safeTransfer(TREASURY, treasury);

        if (!poolOpen) {
            pendingGenesisUsdt += buy + liquidity;
            if (totalMinted == GENESIS_SHARES) _openPool(l);
        } else {
            _settleLiquidity(buy, liquidity, l);
        }
        token.mint(msg.sender, userTokens);
        if (totalMinted == TOTAL_SHARES) _finish();
        IIgnisDapp(dapp).onMint(msg.sender, walletMinted[msg.sender]);
        emit Minted(msg.sender, shares, cost, userTokens);
        if (nativePayment) {
            uint256 refund = msg.value - nativeSpent;
            _refundNative(refund);
            emit NativePayment(msg.sender, nativeSpent, refund, cost);
        }
        return true;
    }

    function _collectPayment(uint256 cost, uint256 deadline, bool nativePayment) private returns (uint256 spent) {
        uint256 balanceBefore = usdt.balanceOf(address(this));
        if (nativePayment) {
            uint256 oracleQuote = _quoteNative(cost);
            uint256 oracleMaximum = Math.mulDiv(oracleQuote, 10_000 + MAX_NATIVE_PREMIUM_BPS, 10_000);
            uint256[] memory quoted = router.getAmountsIn(cost, _path(address(wbnb), address(usdt)));
            if (quoted.length != 2 || quoted[0] == 0 || quoted[1] != cost) revert InvalidNativePayment();
            if (quoted[0] > oracleMaximum) revert NativePriceDeviation();
            uint256 nativeBefore = address(this).balance - msg.value;
            uint256 ceiling = Math.min(msg.value, oracleMaximum);
            uint256[] memory amounts = router.swapETHForExactTokens{value: ceiling}(
                cost, _path(address(wbnb), address(usdt)), address(this), deadline
            );
            if (amounts.length != 2 || amounts[0] == 0 || amounts[0] > ceiling || amounts[1] != cost) {
                revert InvalidNativePayment();
            }
            spent = amounts[0];
            if (address(this).balance != nativeBefore + msg.value - spent) revert InvalidNativePayment();
        } else {
            usdt.safeTransferFrom(msg.sender, address(this), cost);
        }
        if (usdt.balanceOf(address(this)) - balanceBefore != cost) revert InvalidConfig();
    }

    function _refundNative(uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert NativeRefundFailed();
    }

    function _finish() private {
        finished = true;
        token.notifyMintingCompleted();
        emit MintingFinished(totalMinted, totalUserTokens);
    }

    function _openPool(Limits calldata l) private {
        uint256 budget = pendingGenesisUsdt;
        if (budget != openingReferenceUsdt() || token.balanceOf(pair) != 0 || IERC20(pair).totalSupply() != 0) {
            revert InvalidConfig();
        }
        pendingGenesisUsdt = 0;
        uint256 wrappedIn = _swap(budget, _path(address(usdt), address(wbnb)), l.minWbnb, l.deadline, address(this));
        token.mint(pair, OPENING_LP_TOKENS);
        wbnb.safeTransfer(pair, wrappedIn);
        uint256 lp = IV2Pair(pair).mint(lpRecipient);
        if (lp < l.minLiquidity || lp == 0) revert Slippage();
        totalLpMinted += lp;
        poolOpen = true;
        token.openTrading();
        emit PoolOpened(budget, wrappedIn, OPENING_LP_TOKENS, lp);
    }

    function _settleLiquidity(uint256 buy, uint256 liquidity, Limits calldata l) private {
        uint256 bought = _swap(buy, _path(address(usdt), address(token)), l.minBuyTokens, l.deadline, address(this));
        uint256 wrappedIn = _swap(liquidity, _path(address(usdt), address(wbnb)), l.minWbnb, l.deadline, address(this));
        // Deposit all 40% bought tokens + 40% quote funds; no unused router addLiquidity refund.
        // The two sides may differ from the exact reserve ratio; minLiquidity protects the minted LP amount.
        IERC20(address(token)).safeTransfer(pair, bought);
        wbnb.safeTransfer(pair, wrappedIn);
        uint256 lp = IV2Pair(pair).mint(lpRecipient);
        if (lp < l.minLiquidity || lp == 0) revert Slippage();
        totalLpMinted += lp;
        emit LiquidityAdded(buy, liquidity, bought, wrappedIn, lp);
    }

    /// @notice Maximum tokens per tax swap: 100 million IGNIS with the default threshold.
    function taxSwapCap() public view returns (uint256) {
        return swapThreshold * 100;
    }

    /// @notice Swap the available balance up to the current single-transaction cap.
    /// @dev The shared reentrancy lock also protects temporary buy-to-LP tokens during mint settlement.
    function swapTaxToUsdt(uint256 minUsdtOut, uint256 deadline) external nonReentrant returns (uint256 received) {
        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) revert NoTaxToProcess();
        uint256 cap = taxSwapCap();
        if (amount > cap) amount = cap;
        return _swapTax(amount, minUsdtOut, deadline);
    }

    /// @notice Swap exactly the specified token amount; the recipient and quote floor are enforced on chain.
    function swapTaxAmountToUsdt(uint256 amount, uint256 deadline) external nonReentrant returns (uint256 received) {
        if (amount == 0 || amount > token.balanceOf(address(this)) || amount > taxSwapCap()) {
            revert InvalidTaxAmount();
        }
        return _swapTax(amount, 0, deadline);
    }

    function _swapTax(uint256 amount, uint256 minUsdtOut, uint256 deadline) private returns (uint256 received) {
        received = _swap(amount, _path(address(token), address(usdt)), minUsdtOut, deadline, TAX_RECIPIENT);
        totalTaxUsdt += received;
        emit TaxProcessed(amount, received);
    }

    function _path(address from, address to) private view returns (address[] memory path) {
        if (from == address(wbnb) || to == address(wbnb)) {
            path = new address[](2);
            path[0] = from;
            path[1] = to;
        } else {
            path = new address[](3);
            path[0] = from;
            path[1] = address(wbnb);
            path[2] = to;
        }
    }

    function _quote(uint256 amount, address[] memory path) private view returns (uint256) {
        uint256[] memory quote = router.getAmountsOut(amount, path);
        if (quote.length != path.length || quote[quote.length - 1] == 0) revert Slippage();
        return quote[quote.length - 1];
    }

    function _minimumOut(uint256 amount, address[] memory path, uint256 requested) private view returns (uint256) {
        uint256 floor = Math.mulDiv(_quote(amount, path), MIN_QUOTE_BPS, 10_000);
        if (floor == 0) floor = 1;
        return requested > floor ? requested : floor;
    }

    function _swap(uint256 amount, address[] memory path, uint256 requested, uint256 deadline, address recipient)
        private
        returns (uint256 received)
    {
        IERC20 output = IERC20(path[path.length - 1]);
        IERC20 input = IERC20(path[0]);
        uint256 beforeBalance = output.balanceOf(recipient);
        uint256 floor = _minimumOut(amount, path, requested);
        input.forceApprove(address(router), amount);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, floor, path, recipient, deadline);
        input.forceApprove(address(router), 0);
        received = output.balanceOf(recipient) - beforeBalance;
        if (received < floor) revert Slippage();
    }
}
