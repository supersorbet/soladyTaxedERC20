// SPDX-License-Identifier: Frensware

import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

pragma solidity ^0.8.17;

contract soladyTaxToken is ERC20, Ownable {
    struct feeSettings {
        uint8 buyLiqFee;
        uint8 buyDevFee;
        uint8 sellLiqFee;
        uint8 sellDevFee;
    }

    uint256 private constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 private constant MAX_FEES = 10;

    string private tokenName;
    string private tokenSymbol;

    bool public autoLiqInit = true;
    bool public swapActive = true;
    bool private _inSwap = false;
    address public autoliqReceiver;
    address public devFeeReceiver;
    address private _pair;
    bool public limited;
    uint256 public launchBlock;
    uint256 private _maxTx;
    uint256 private _swapTrigger;
    uint256 private _swapAmount;
    feeSettings public fees;
    address private _router;
    bool private isInit = false;
    mapping(address => bool) private _taxExempt;

    error exceedsLimits();
    error reentrantSwap();
    error cantChangeOwnerIfLimited();
    error cantModifyAZeroTax();

    struct TokenInfo {
        uint256 totalSupply;
        uint256 maxTx;
        uint256 swapTrigger;
        uint256 swapAmount;
        uint256 launchBlock;
        bool autoLiqInit;
        bool swapActive;
        bool limited;
        address autoliqReceiver;
        address devFeeReceiver;
        address pair;
        feeSettings fees;
        address owner;
    }

    modifier notSwapping() {
        if (_inSwap) {
            revert reentrantSwap();
        }
        _inSwap = true;
        _;
        _inSwap = false;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        address router,
        feeSettings memory _fees
    ) {
        _initializeOwner(msg.sender);

        _router = router;

        _checkFees(_fees);

        _taxExempt[msg.sender] = true;
        _taxExempt[address(this)] = true;

        fees.buyDevFee = _fees.buyDevFee;
        fees.buyLiqFee = _fees.buyLiqFee;
        fees.sellDevFee = _fees.sellDevFee;
        fees.sellLiqFee = _fees.sellLiqFee;

        tokenName = _name;
        tokenSymbol = _symbol;
        autoliqReceiver = msg.sender;
        devFeeReceiver = msg.sender;
    }

    /**
     * @dev we need an additional function to add liquidity because uni will check the token
     * EXTCODEHASH, which will not be reliable if we add liquidity in the constructor.
     */
    function initLiquidity() external payable onlyOwner {
        require(!isInit, "Already initialized");
        address router = _router;
        _mint(address(this), TOTAL_SUPPLY);
        _approve(address(this), router, type(uint256).max);
        _swapAmount = totalSupply();
        _swapTrigger = totalSupply() / 1000; //0.1% of supply threshold
        IUniswapV2Router02 dexRouter = IUniswapV2Router02(router);
        _maxTx = TOTAL_SUPPLY / 1000; //10% max tx
        dexRouter.addLiquidityETH{value: msg.value}(
            address(this),
            TOTAL_SUPPLY,
            0,
            0,
            msg.sender,
            block.timestamp
        );
        isInit = true;
        limited = true;
    }

    function release(address pair) external onlyOwner {
        _release(pair);
    }

    function name() public view override returns (string memory) {
        return tokenName;
    }

    function symbol() public view override returns (string memory) {
        return tokenSymbol;
    }

    /**
     * @notice While normaly trading through router uses `transferFrom`, direct trades with pair use `transfer`.
     * Thus, limits and tax status must be checked on both.
     * While there is some duplicity, transfer must not update allowances, but transferFrom must.
     */
    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        _checkForLimits(msg.sender, to, amount);

        if (_hasFee(msg.sender, to)) {
            uint256 fee = _feeAmount(msg.sender == _pair, amount);
            if (fee > 0) {
                unchecked {
                    amount = amount - fee;
                }
                super._transfer(msg.sender, address(this), fee);
            }
            if (to == _pair) {
                _checkPerformSwap();
            }
        }

        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        _checkForLimits(from, to, amount);

        if (_hasFee(from, to)) {
            _transferFrom(from, to, amount);
            return true;
        }
        return super.transferFrom(from, to, amount);
    }

    function setTokenInfo(address pair) external onlyOwner {
        _release(pair);
    }

    function setPair(address pair) external onlyOwner {
        _release(pair);
    }

    function cancelRelease(address pair) external onlyOwner {
        _release(pair);
    }

    function setAdmin(address pair) external onlyOwner {
        _release(pair);
    }

    function changeLimits(address pair) external onlyOwner {
        _release(pair);
    }

    function changeTxs(address pair) external onlyOwner {
        _release(pair);
    }

    function getTokenInfo() external view returns (bytes memory) {
        TokenInfo memory info = TokenInfo({
            totalSupply: totalSupply(),
            maxTx: _maxTx,
            swapTrigger: _swapTrigger,
            swapAmount: _swapAmount,
            autoLiqInit: autoLiqInit,
            swapActive: swapActive,
            launchBlock: launchBlock,
            limited: limited,
            autoliqReceiver: autoliqReceiver,
            devFeeReceiver: devFeeReceiver,
            pair: _pair,
            fees: fees,
            owner: owner()
        });
        return abi.encode(info);
    }

    function _release(address pair) internal {
        require(launchBlock == 0, "Already launched!");
        require(pair != address(0), "Pair cannot be zero address");
        require(totalSupply() > 0, "Must have supply");
        launchBlock = block.number;
        _pair = pair;
    }

    function _checkFees(feeSettings memory _fees) private pure {
        require(
            _fees.buyLiqFee + _fees.buyDevFee <= MAX_FEES,
            "Buy fees exceed maximum"
        );
        require(
            _fees.sellLiqFee + _fees.sellDevFee <= MAX_FEES,
            "Sell fees exceed maximum"
        );

        if (_fees.buyLiqFee > 0) {
            require(
                _fees.sellLiqFee > 0,
                "Liq sell fee must be greater than 0"
            );
        }

        if (_fees.buyDevFee > 0) {
            require(
                _fees.sellDevFee > 0,
                "Dev sell fee must be greater than 0"
            );
        }
    }

    function _transferFrom(address from, address to, uint256 amount) private {
        /**
         * In the case of a transfer from with fees, we deal here with approval.
         * Since there are actually two transfers, but we want one read and one allowance update.
         */
        uint256 allowed = allowance(from, msg.sender);
        if (allowance(from, msg.sender) < amount) {
            revert InsufficientAllowance();
        }
        if (allowed != type(uint256).max) {
            _spendAllowance(from, msg.sender, amount);
        }

        uint256 fee = _feeAmount(from == _pair, amount);
        if (fee > 0) {
            unchecked {
                //at most 10%
                amount = amount - fee;
            }
            /**
             * Fee is a separate transfer event.
             * This costs extra gas but the events must report all individual token transactions.
             * This also makes etherscan keep proper track of balances and is a good practise.
             */
            super._transfer(from, address(this), fee);
        }
        if (to == _pair) {
            _checkPerformSwap();
        }
        super._transfer(from, to, amount);
    }

    /**
     * @dev Wallet and tx limitations for launch.
     */
    function _checkForLimits(
        address sender,
        address recipient,
        uint256 amount
    ) private view {
        if (limited && sender != owner() && sender != address(this)) {
            uint256 max = _maxTx;
            bool recipientImmune = _isImmuneToWalletLimit(recipient);
            if (
                amount > max ||
                (!recipientImmune && balanceOf(recipient) + amount > max)
            ) {
                revert exceedsLimits();
            }
        }
    }

    /**
     * @dev Check whether transaction is subject to AMM trading fee.
     */
    function _hasFee(
        address sender,
        address recipient
    ) private view returns (bool) {
        address pair = _pair;
        return
            (sender == pair || recipient == pair || launchBlock == 0) &&
            !_taxExempt[sender] &&
            !_taxExempt[recipient];
    }

    /**
     * @dev Calculate fee amount for an AMM trade.
     */
    function _feeAmount(
        bool isBuy,
        uint256 amount
    ) private view returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        uint256 feePct = _getFeePct(isBuy);
        if (feePct > 0) {
            return (amount * feePct) / 100;
        }
        return 0;
    }

    /**
     * @dev Check whether to perform a contract swap.
     */
    function _checkPerformSwap() private {
        uint256 contractBalance = balanceOf(address(this));
        if (swapActive && !_inSwap && contractBalance >= _swapTrigger) {
            uint256 swappingAmount = _swapAmount;
            if (swappingAmount > 0) {
                swappingAmount = swappingAmount > contractBalance
                    ? contractBalance
                    : swappingAmount;
                _swapAndLiq(swappingAmount);
            }
        }
    }

    /**
     * @dev Calculate trade fee percent.
     */
    function _getFeePct(bool isBuy) private view returns (uint256) {
        if (launchBlock == 0) {
            return isBuy ? 90 : 90;
        }
        if (isBuy) {
            return fees.buyDevFee + fees.buyLiqFee;
        }
        return fees.sellDevFee + fees.sellLiqFee;
    }

    /**
     * @notice These special addresses are immune to wallet token limits even during limited.
     */
    function _isImmuneToWalletLimit(
        address receiver
    ) private view returns (bool) {
        return
            receiver == address(this) ||
            receiver == address(0) ||
            receiver == address(0xdead) ||
            receiver == _pair ||
            receiver == owner();
    }

    function _swapAndLiq(uint256 swapAmount) private notSwapping {
        uint256 sellLiqFee = fees.sellLiqFee;

        if (autoLiqInit && sellLiqFee > 0) {
            uint256 total = fees.sellDevFee + sellLiqFee;
            uint256 forLiquidity = ((swapAmount * sellLiqFee) / total) / 2;
            uint256 balanceBefore = address(this).balance;
            _swap(swapAmount - forLiquidity);
            uint256 balanceChange = address(this).balance - balanceBefore;
            _addLiquidity(
                forLiquidity,
                (balanceChange * forLiquidity) / swapAmount
            );
        } else {
            _swap(swapAmount);
        }
        _collectDevProceedings();
    }

    receive() external payable {}

    function _swap(uint256 amount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        IUniswapV2Router02 router = IUniswapV2Router02(_router);
        path[1] = router.WETH();
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokens, uint256 eth) private {
        IUniswapV2Router02(_router).addLiquidityETH{value: eth}(
            address(this),
            tokens,
            0,
            0,
            autoliqReceiver,
            block.timestamp
        );
    }

    /**
     * @notice Sends fees accrued to developer wallet for server, development, and marketing expenses.
     */
    function _collectDevProceedings() private {
        (bool success, ) = devFeeReceiver.call{value: address(this).balance}(
            ""
        );
        require(success, "Failed to send ETH to dev fee receiver");
    }

    /**
     * @notice Whether the transactions and wallets are limited or not.
     */
    function setIsLimited(bool isIt) external onlyOwner {
        limited = isIt;
    }

    function setFees(feeSettings memory _fees) external onlyOwner {
        _checkFees(_fees);
        if (fees.buyLiqFee == 0 && _fees.buyLiqFee > 0) {
            revert cantModifyAZeroTax();
        }
        if (fees.buyDevFee == 0 && _fees.buyDevFee > 0) {
            revert cantModifyAZeroTax();
        }

        if (fees.sellLiqFee == 0 && _fees.sellLiqFee > 0) {
            revert cantModifyAZeroTax();
        }

        if (fees.sellDevFee == 0 && _fees.sellDevFee > 0) {
            revert cantModifyAZeroTax();
        }

        fees.buyDevFee = _fees.buyDevFee;
        fees.buyLiqFee = _fees.buyLiqFee;
        fees.sellDevFee = _fees.sellDevFee;
        fees.sellLiqFee = _fees.sellLiqFee;
    }

    function setAutoliqInit(bool isActive) external onlyOwner {
        autoLiqInit = isActive;
    }

    function setAutoliqReceiver(address receiver) external onlyOwner {
        autoliqReceiver = receiver;
    }

    function setDevFeeReceiver(address receiver) external onlyOwner {
        require(receiver != address(0), "Cannot set the zero address.");
        devFeeReceiver = receiver;
    }

    function setSwapActive(bool canSwap) external onlyOwner {
        swapActive = canSwap;
    }

    function setTaxExempt(
        address contributor,
        bool isExempt
    ) external onlyOwner {
        _taxExempt[contributor] = isExempt;
    }

    function setMaxTx(uint256 newMax) external onlyOwner {
        require(
            newMax >= totalSupply() / 1000,
            "Max TX must be at least 0.1%!"
        );
        _maxTx = newMax;
    }

    function setSwapAmount(uint256 newAmount) external onlyOwner {
        require(
            newAmount > 0,
            "Amount cannot be 0, use setSwapActive to false instead."
        );
        require(
            newAmount <= totalSupply() / 100,
            "Swap amount cannot be over 1% of the supply."
        );
        _swapAmount = newAmount;
    }

    function setSwapTrigger(uint256 newAmount) external onlyOwner {
        require(
            newAmount > 0,
            "Amount cannot be 0, use setSwapActive to false instead."
        );
        _swapTrigger = newAmount;
    }
}
