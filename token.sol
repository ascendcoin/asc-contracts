// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/uniswap-factory.sol";
import "./interfaces/uniswap-v2.sol";

import "./libs/ownable.sol";
import "./libs/erc20.sol";
import "./libs/safe-math.sol";
import "./libs/reentrancy-guard.sol";

contract Ascend is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;
    
    address public treasury = address(0x2D924EE1652995fFA9A2DA02666A940CecaDB820); // treasury
    address public presale; // presale
    address public immutable dead = 0x000000000000000000000000000000000000dEaD;
    
    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;

    mapping (address => bool) private _isExcludedFromFee;
    mapping (address => bool) private _isExcluded;
    address[] private _excluded;
   
    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 1000000 * 10**9;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _tFeeTotal;

    string private _name = "Ascend";
    string private _symbol = "ASC";
    uint8 private _decimals = 9;

    uint256 public _tF = 2;
    uint256 private _prevTF = _tF;
    
    uint256 public _lF = 10;
    uint256 private _prevLF = _lF;
    
    uint256 public _maxTxAmount = 3000 * 10**9;
    uint256 public minBeforeSwap = 200 * 10**9; 
    uint256 public minBeforeBB = 1 * 10**17;
    uint256 public buyBackUL = 1 * 10**17;
    uint256 public buyChunk = 25;

    IUniswapV2Router02 public immutable quickswap;
    address public immutable pair;
    
    bool inSwap;
    bool public swapEnabled = false;
    bool public bbEnabled = false;

    address public weth = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    
    event SwapAndBBUpdated(bool swap, bool bb);
    event LiquidityAdded(uint256 _token, uint256 _wei);
    
    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }
    
    constructor () public {
        _rOwned[_msgSender()] = _rTotal;
        
        IUniswapV2Router02 _quickswap = IUniswapV2Router02(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
        pair = IUniswapV2Factory(_quickswap.factory())
            .createPair(address(this), weth);

        quickswap = _quickswap;

        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;
        
        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: !allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: !allowance"));
        return true;
    }

    function isExcludedFromReward(address account) public view returns (bool) {
        return _isExcluded[account];
    }

    function totalFees() public view returns (uint256) {
        return _tFeeTotal;
    }

    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns(uint256) {
        require(tAmount <= _tTotal, "!amount");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,,) = _getValues(tAmount);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,,) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "!amount");
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }

    function excludeFromReward(address account) public onlyOwner() {
        require(!_isExcluded[account], "!excluded");
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeInReward(address account) external onlyOwner() {
        require(_isExcluded[account], "!excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: !address");
        require(spender != address(0), "ERC20: !address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(from != address(0), "ERC20: !address");
        require(to != address(0), "ERC20: !address");
        require(amount > 0, "!zero");
        
        if (from != owner() && from != presale && to != owner()) {
            require(amount <= _maxTxAmount, "!max");
        }

        uint256 balance = balanceOf(address(this));
        bool overMin = balance >= minBeforeSwap;
        
        if (!inSwap && swapEnabled && from != pair) {
            if (overMin) {
                balance = minBeforeSwap;
                swapTokens(balance);    
            }

	        uint256 _weth = IERC20(weth).balanceOf(address(this));
            if (bbEnabled && _weth > minBeforeBB) {
                
                if (_weth > buyBackUL)
                    _weth = buyBackUL;
                
                doBB(_weth.div(buyChunk));
            }
        }
        
        bool takeFee = true;
        
        //if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFee[from] || _isExcludedFromFee[to]){
            takeFee = false;
        }
        
        _tokenTransfer(from, to, amount, takeFee);
    }

    function swapTokens(uint256 bal) private lockTheSwap {
        // swap token balance
        uint256 _swap = bal.mul(85).div(100);
        uint256 _left = bal.sub(_swap);
        uint256 _weth = IERC20(weth).balanceOf(address(this));
        swapForWETH(_swap);
        uint256 total = IERC20(weth).balanceOf(address(this)).sub(_weth);

        // add to treasury (0.3 * 100 / 85)
        uint256 _t = total.div(_lF).mul(3).mul(100).div(85);
        IERC20(weth).safeTransfer(treasury, _t);

        // buyback amount (0.4 * 100 / 85)
        uint256 _b = total.div(_lF).mul(4).mul(100).div(85);
        uint256 _l = total.sub(_t).sub(_b);
        addLiquidity(_left, _l);
    }
    
    function doBB(uint256 amount) private lockTheSwap {
    	if (amount > 0) {
    	    swapForTokens(amount);
	    }
    }
    
    function swapForWETH(uint256 amount) private {
        // generate the quickswap pair path of token -> wmatic
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = weth;
        path[2] = quickswap.WETH();

        _approve(address(this), address(quickswap), amount);

        uint256 bal = address(this).balance;
        quickswap.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp.add(300));
        uint256 rcv = address(this).balance.sub(bal);

        // generate the quickswap pair path of wmatic -> weth
        address[] memory path2 = new address[](2);
        path2[0] = quickswap.WETH();
        path2[1] = weth;

        quickswap.swapExactETHForTokensSupportingFeeOnTransferTokens{value: rcv}(0, path2, address(this), block.timestamp.add(300));
    }
    
    function swapForTokens(uint256 amount) private {
        // generate the quickswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(this);
        
        IERC20(weth).approve(address(quickswap), amount);

        // make the swap
        quickswap.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, dead, block.timestamp.add(300));
    }
    
    function addLiquidity(uint256 _token, uint256 _weth) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(quickswap), _token);
        IERC20(weth).approve(address(quickswap), _weth);

        // add the liquidity
        quickswap.addLiquidity(address(this), weth, _token, _weth, 0, 0, address(this), block.timestamp.add(300));

        emit LiquidityAdded(_token, _weth);
    }

    function _tokenTransfer(address sender, address recipient, uint256 amount, bool takeFee) private {
        if(!takeFee)
            remove();
        
        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }
        
        if(!takeFee)
            restore();
    }

    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
	    _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);           
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
    	_tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);   
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
    	_tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);        
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getTValues(tAmount);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, tLiquidity, _getRate());
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tLiquidity);
    }

    function _getTValues(uint256 tAmount) private view returns (uint256, uint256, uint256) {
        uint256 tFee = calcTF(tAmount);
        uint256 tLiquidity = calcLF(tAmount);
        uint256 tTransferAmount = tAmount.sub(tFee).sub(tLiquidity);
        return (tTransferAmount, tFee, tLiquidity);
    }

    function _getRValues(uint256 tAmount, uint256 tFee, uint256 tLiquidity, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);
        uint256 rFee = tFee.mul(currentRate);
        uint256 rLiquidity = tLiquidity.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rFee).sub(rLiquidity);
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;      
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
    
    function _takeLiquidity(uint256 tLiquidity) private {
        uint256 currentRate =  _getRate();
        uint256 rLiquidity = tLiquidity.mul(currentRate);
        _rOwned[address(this)] = _rOwned[address(this)].add(rLiquidity);
        if(_isExcluded[address(this)])
            _tOwned[address(this)] = _tOwned[address(this)].add(tLiquidity);
    }
    
    function calcTF(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_tF).div(
            10**2
        );
    }
    
    function calcLF(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_lF).div(
            10**2
        );
    }
    
    function remove() private {
        if(_tF == 0 && _lF == 0) return;
        
        _prevTF = _tF;
        _prevLF = _lF;
        
        _tF = 0;
        _lF = 0;
    }
    
    function restore() private {
        _tF = _prevTF;
        _lF = _prevLF;
    }

    function isExcludedFromFee(address account) public view returns(bool) {
        return _isExcludedFromFee[account];
    }
    
    function excludeFromFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }
    
    function includeInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }
    
    function setFees(uint256 tF, uint256 lF) external onlyOwner {
        _tF = tF;
        _lF = lF;
    }
    
    function setAmounts(uint256 max, uint256 chunk) external onlyOwner {
        _maxTxAmount = max;
        buyChunk = chunk;
    }

    function setMin(uint256 swap, uint256 bb) external onlyOwner {
        minBeforeSwap = swap;
        minBeforeBB = bb;
    }
    
    function setUL(uint256 limit) external onlyOwner {
        buyBackUL = limit;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }
    
    function setPresale(address _presale) external onlyOwner {
        presale = _presale;
    }

    function setEnabled(bool _swap, bool _bb) public onlyOwner {
        swapEnabled = _swap;
        bbEnabled = _bb;
        emit SwapAndBBUpdated(_swap, _bb);
    }
    
    function start() external onlyOwner {
        setEnabled(true, true);
    }
    
    receive() external payable {}
}