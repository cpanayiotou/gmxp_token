// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./Roles.sol";
import "./Tokenomics.sol";
import "./Schemes.sol";

contract GamersXP is
    Initializable,
    ERC20Upgradeable,
    UUPSUpgradeable,
    Tokenomics,
    Schemes,
    Roles
{
    uint16 private constant FEES_DIVISOR = 10**4;
    uint256 private constant MAX = ~uint256(0);

    uint256 private maxTransactionAmount;
    uint256 private maxWalletBalance;
    uint256 private TOTAL_SUPPLY;
    uint256 private _reflectedSupply;

    address[] private _excluded;

    event Rewarded(address indexed player, uint256 amount, string challengeId);

    function initialize(
        address _dailyOperationsAddress,
        address _advisorsAddress,
        address _burnAddress
    ) public initializer {
        __ERC20_init("Super Supreme Silver", "SSS");
        __AccessControl_init();
        __UUPSUpgradeable_init();

        //set accounts
        dailyOperationsAddress = _dailyOperationsAddress;
        advisorsAddress = _advisorsAddress;
        burnAddress = _burnAddress;

        //set tokenomics
        _addFees();

        TOTAL_SUPPLY = 600000000 * 10**decimals();
        _reflectedSupply = (MAX - (MAX % TOTAL_SUPPLY));
        maxTransactionAmount = TOTAL_SUPPLY / 100;

        _reflectedBalances[address(this)] = _reflectedSupply;

        _transferTokens(
            address(this),
            msg.sender,
            180000000 * 10**decimals(),
            false
        );
        _transferTokens(
            address(this),
            dailyOperationsAddress,
            60000000 * 10**decimals(),
            false
        );

        _transferTokens(
            address(this),
            advisorsAddress,
            60000000 * 10**decimals(),
            false
        );
        //admin/Team priveleges
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(PAUSER_ROLE, msg.sender);
        _setupRole(DAILY_OPERATIONS_ROLE, msg.sender);

        //daily Operations Wallet
        _setupRole(DAILY_OPERATIONS_ROLE, dailyOperationsAddress);

        // exclude admin <owner> and this contract from fee
        _isExcludedFromFee[msg.sender] = true;
        _isExcludedFromFee[address(this)] = true;

        // exclude the owner and this contract from rewards
        _exclude(msg.sender);
        _exclude(address(this));
        _exclude(burnAddress);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}

    function addScheme(
        uint8 schemeType,
        uint256 schemeValue,
        uint256 purchaseAmount,
        uint256 validThru,
        uint16 expirationDays
    ) public onlyRole(DAILY_OPERATIONS_ROLE) returns (uint256) {
        return
            _addScheme(
                schemeType,
                schemeValue,
                purchaseAmount,
                validThru,
                expirationDays
            );
    }

    function updateScheme(
        uint256 id,
        uint8 schemeType,
        uint256 schemeValue,
        uint256 purchaseAmount,
        uint256 validThru,
        uint16 expirationDays
    ) public onlyRole(DAILY_OPERATIONS_ROLE) {
        _updateScheme(
            id,
            schemeType,
            schemeValue,
            purchaseAmount,
            validThru,
            expirationDays
        );
    }

    /** Functions required by IERC20 DECIMALS 10 **/
    function decimals() public pure override returns (uint8) {
        return 10;
    }

    /** Functions required by IERC20 **/
    function totalSupply() public view override returns (uint256) {
        return TOTAL_SUPPLY;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcludedFromRewards[account]) return _balances[account];
        return tokenFromReflection(_reflectedBalances[account]);
    }

    /** Functions required by IERC20 - END **/

    /**
     * @dev this is really a "soft" burn (total supply is not reduced). RFI holders
     * get two benefits from burning tokens:
     *
     * 1) Tokens in the burn address increase the % of tokens held by holders not
     *    excluded from rewards (assuming the burn address is excluded)
     * 2) Tokens in the burn address cannot be sold (which in turn draing the
     *    liquidity pool)
     *
     *
     * In RFI holders already get % of each transaction so the value of their tokens
     * increases (in a way). Therefore there is really no need to do a "hard" burn
     * (reduce the total supply). What matters (in RFI) is to make sure that a large
     * amount of tokens cannot be sold = draining the liquidity pool = lowering the
     * value of tokens holders own. For this purpose, transfering tokens to a (vanity)
     * burn address is the most appropriate way to "burn".
     *
     * There is an extra check placed into the `transfer` function to make sure the
     * burn address cannot withdraw the tokens is has (although the chance of someone
     * having/finding the private key is virtually zero).
     */
    function burn(uint256 amount) external {
        address sender = _msgSender();
        require(
            sender != address(0),
            "BaseRfiToken: burn from the zero address"
        );
        require(
            sender != address(burnAddress),
            "BaseRfiToken: burn from the burn address"
        );

        uint256 balance = balanceOf(sender);
        require(balance >= amount, "BaseRfiToken: burn amount exceeds balance");

        uint256 reflectedAmount = amount * _getCurrentRate();

        // remove the amount from the sender's balance first
        _reflectedBalances[sender] =
            _reflectedBalances[sender] -
            reflectedAmount;
        if (_isExcludedFromRewards[sender])
            _balances[sender] = _balances[sender] - amount;

        _burnTokens(sender, amount, reflectedAmount);
    }

    /**
     * @dev "Soft" burns the specified amount of tokens by sending them
     * to the burn address
     */
    function _burnTokens(
        address sender,
        uint256 tBurn,
        uint256 rBurn
    ) internal {
        /**
         * @dev Do not reduce _totalSupply and/or _reflectedSupply. (soft) burning by sending
         * tokens to the burn address (which should be excluded from rewards) is sufficient
         * in RFI
         */
        _reflectedBalances[burnAddress] =
            _reflectedBalances[burnAddress] +
            rBurn;
        if (_isExcludedFromRewards[burnAddress])
            _balances[burnAddress] = _balances[burnAddress] + tBurn;

        /**
         * @dev Emit the event so that the burn address balance is updated (on bscscan)
         */
        emit Transfer(sender, burnAddress, tBurn);
    }

    function isExcludedFromReward(address account)
        external
        view
        returns (bool)
    {
        return _isExcludedFromRewards[account];
    }

    /**
     * @dev Calculates and returns the reflected amount for the given amount with or without
     * the transfer fees (deductTransferFee true/false)
     */
    function reflectionFromToken(uint256 tAmount, bool deductTransferFee)
        external
        view
        returns (uint256)
    {
        require(tAmount <= TOTAL_SUPPLY, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount, , , , ) = _getValues(tAmount, 0);
            return rAmount;
        } else {
            (, uint256 rTransferAmount, , , ) = _getValues(
                tAmount,
                _getSumOfFees(_msgSender(), tAmount)
            );
            return rTransferAmount;
        }
    }

    /**
     * @dev Calculates and returns the amount of tokens corresponding to the given reflected amount.
     */
    function tokenFromReflection(uint256 rAmount)
        internal
        view
        returns (uint256)
    {
        require(
            rAmount <= _reflectedSupply,
            "Amount must be less than total reflections"
        );
        uint256 currentRate = _getCurrentRate();
        return rAmount / currentRate;
    }

    function excludeFromReward(address account)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(!_isExcludedFromRewards[account], "Account is not included");
        _exclude(account);
    }

    function _exclude(address account) internal {
        if (_reflectedBalances[account] > 0) {
            _balances[account] = tokenFromReflection(
                _reflectedBalances[account]
            );
        }
        _isExcludedFromRewards[account] = true;
        _excluded.push(account);
    }

    function includeInReward(address account)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_isExcludedFromRewards[account], "Account is not excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _balances[account] = 0;
                _isExcludedFromRewards[account] = false;
                _excluded.pop();
                break;
            }
        }
    }

    function setExcludedFromFee(address account, bool value)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _isExcludedFromFee[account] = value;
    }

    function isExcludedFromFee(address account) public view returns (bool) {
        return _isExcludedFromFee[account];
    }

    /**
     */
    function _isUnlimitedSender(address account) internal view returns (bool) {
        // the owner should be the only whitelisted sender
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }

    /**
     */
    function _isUnlimitedRecipient(address account)
        internal
        view
        returns (bool)
    {
        // the owner should be a white-listed recipient
        // and anyone should be able to burn as many tokens as
        // he/she wants
        return (hasRole(DEFAULT_ADMIN_ROLE, account) || account == burnAddress);
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(
            sender != address(burnAddress),
            "ERC20: transfer from the burn address"
        );
        require(amount > 0, "Transfer amount must be greater than zero");

        // indicates whether or not feee should be deducted from the transfer
        bool takeFee = true;

        /**
         * Check the amount is within the max allowed limit as long as a
         * unlimited sender/recepient is not involved in the transaction
         */
        if (
            amount > maxTransactionAmount &&
            !_isUnlimitedSender(sender) &&
            !_isUnlimitedRecipient(recipient)
        ) {
            revert("Transfer amount exceeds the maxTxAmount.");
        }
        /**
         * The pair needs to excluded from the max wallet balance check;
         * selling tokens is sending them back to the pair (without this
         * check, selling tokens would not work if the pair's balance
         * was over the allowed max)
         *
         * Note: This does NOT take into account the fees which will be deducted
         *       from the amount. As such it could be a bit confusing
         */
        if (
            maxWalletBalance > 0 &&
            !_isUnlimitedSender(sender) &&
            !_isUnlimitedRecipient(recipient)
        ) {
            uint256 recipientBalance = balanceOf(recipient);
            require(
                recipientBalance + amount <= maxWalletBalance,
                "New balance would exceed the maxWalletBalance"
            );
        }

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if (_isExcludedFromFee[sender] || _isExcludedFromFee[recipient]) {
            takeFee = false;
        }

        _transferTokens(sender, recipient, amount, takeFee);
    }

    function _transferTokens(
        address sender,
        address recipient,
        uint256 amount,
        bool takeFee
    ) private {
        /**
         * We don't need to know anything about the individual fees here
         * (like Safemoon does with `_getValues`). All that is required
         * for the transfer is the sum of all fees to calculate the % of the total
         * transaction amount which should be transferred to the recipient.
         *
         * The `_takeFees` call will/should take care of the individual fees
         */
        uint256 sumOfFees = _getSumOfFees(sender, amount);
        if (!takeFee) {
            sumOfFees = 0;
        }

        (
            uint256 rAmount,
            uint256 rTransferAmount,
            uint256 tAmount,
            uint256 tTransferAmount,
            uint256 currentRate
        ) = _getValues(amount, sumOfFees);

        /**
         * Sender's and Recipient's reflected balances must be always updated regardless of
         * whether they are excluded from rewards or not.
         */
        _reflectedBalances[sender] = _reflectedBalances[sender] - rAmount;
        _reflectedBalances[recipient] =
            _reflectedBalances[recipient] +
            rTransferAmount;

        /**
         * Update the true/nominal balances for excluded accounts
         */
        if (_isExcludedFromRewards[sender]) {
            _balances[sender] = _balances[sender] - tAmount;
        }
        if (_isExcludedFromRewards[recipient]) {
            _balances[recipient] = _balances[recipient] + tTransferAmount;
        }

        _takeFees(amount, currentRate, sumOfFees);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _takeFees(
        uint256 amount,
        uint256 currentRate,
        uint256 sumOfFees
    ) private {
        if (sumOfFees > 0) {
            _takeTransactionFees(amount, currentRate);
        }
    }

    function _getValues(uint256 tAmount, uint256 feesSum)
        internal
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 tTotalFees = (tAmount * feesSum) / FEES_DIVISOR;
        uint256 tTransferAmount = tAmount - tTotalFees;
        uint256 currentRate = _getCurrentRate();
        uint256 rAmount = tAmount * currentRate;
        uint256 rTotalFees = tTotalFees * currentRate;
        uint256 rTransferAmount = rAmount - rTotalFees;

        return (
            rAmount,
            rTransferAmount,
            tAmount,
            tTransferAmount,
            currentRate
        );
    }

    function _getCurrentRate() internal view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply / tSupply;
    }

    function _getCurrentSupply() internal view returns (uint256, uint256) {
        uint256 rSupply = _reflectedSupply;
        uint256 tSupply = TOTAL_SUPPLY;

        /**
         * The code below removes balances of addresses excluded from rewards from
         * rSupply and tSupply, which effectively increases the % of transaction fees
         * delivered to non-excluded holders
         */
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (
                _reflectedBalances[_excluded[i]] > rSupply ||
                _balances[_excluded[i]] > tSupply
            ) return (_reflectedSupply, TOTAL_SUPPLY);
            rSupply = rSupply - _reflectedBalances[_excluded[i]];
            tSupply = tSupply - _balances[_excluded[i]];
        }
        if (tSupply == 0 || rSupply < _reflectedSupply / TOTAL_SUPPLY)
            return (_reflectedSupply, TOTAL_SUPPLY);
        return (rSupply, tSupply);
    }

    /**
     * @dev Returns the total sum of fees to be processed in each transaction.
     *
     * To separate concerns this contract (class) will take care of ONLY handling RFI, i.e.
     * changing the rates and updating the holder's balance (via `_redistribute`).
     * It is the responsibility of the dev/user to handle all other fees and taxes
     * in the appropriate contracts (classes).
     */
    function _getSumOfFees(address sender, uint256 amount)
        internal
        view
        returns (uint256)
    {
        return _getAntiwhaleFees(balanceOf(sender), amount);
    }

    function _getAntiwhaleFees(uint256, uint256)
        internal
        view
        returns (uint256)
    {
        return sumOfFees;
    }

    /**
     * @dev Redistributes the specified amount among the current holders via the reflect.finance
     * algorithm, i.e. by updating the _reflectedSupply (_rSupply) which ultimately adjusts the
     * current rate used by `tokenFromReflection` and, in turn, the value returns from `balanceOf`.
     * This is the bit of clever math which allows rfi to redistribute the fee without
     * having to iterate through all holders.
     *
     * Visit our discord at https://discord.gg/dAmr6eUTpM
     */
    function _redistribute(
        uint256 amount,
        uint256 currentRate,
        uint256 fee,
        uint256 index
    ) internal {
        uint256 tFee = (amount * fee) / FEES_DIVISOR;
        uint256 rFee = tFee * currentRate;

        _reflectedSupply = _reflectedSupply - rFee;
        _addFeeCollectedAmount(index, tFee);
    }

    function _burn(
        uint256 amount,
        uint256 currentRate,
        uint256 fee,
        uint256 index
    ) private {
        uint256 tBurn = (amount * fee) / FEES_DIVISOR;
        uint256 rBurn = tBurn * currentRate;

        _burnTokens(address(this), tBurn, rBurn);
        _addFeeCollectedAmount(index, tBurn);
    }

    function _takeFee(
        uint256 amount,
        uint256 currentRate,
        uint256 fee,
        address recipient,
        uint256 index
    ) private {
        uint256 tAmount = (amount * fee) / FEES_DIVISOR;
        uint256 rAmount = tAmount * currentRate;

        _reflectedBalances[recipient] = _reflectedBalances[recipient] + rAmount;
        if (_isExcludedFromRewards[recipient])
            _balances[recipient] = _balances[recipient] + tAmount;

        _addFeeCollectedAmount(index, tAmount);
    }

    /**
     * @dev Hook that is called before the `Transfer` event is emitted if fees are enabled for the transfer
     */
    function _takeTransactionFees(uint256 amount, uint256 currentRate)
        internal
    {
        uint256 feesCount = _getFeesCount();
        for (uint256 index = 0; index < feesCount; index++) {
            (FeeType name, uint256 value, address recipient, ) = _getFee(index);
            // no need to check value < 0 as the value is uint (i.e. from 0 to 2^256-1)
            if (value == 0) continue;

            if (name == FeeType.Rfi) {
                _redistribute(amount, currentRate, value, index);
            } else if (name == FeeType.Burn) {
                _burn(amount, currentRate, value, index);
            } else {
                _takeFee(amount, currentRate, value, recipient, index);
            }
        }
    }

    function buyScheme(uint256 schemeId) public {
        _isValidBuyTransaction(schemeId, balanceOf(msg.sender));
        uint256 purchaseAmount = getScheme(schemeId).purchaseAmount;
        _transfer(msg.sender, dailyOperationsAddress, purchaseAmount);
        _assignScheme(msg.sender, schemeId);
    }

    function reward(
        address player,
        uint256 rewardAmount,
        string memory challendId
    ) public onlyRole(DAILY_OPERATIONS_ROLE) {
        uint256 rewardWithSchemeBonus;

        Assigned[] memory playerSchemes = assignedSchemes[player];
        for (uint256 current = 0; current < playerSchemes.length; current++) {
            ///@dev check if the player has the scheme assigned and if the scheme is active (i.e. not expired), 86400 is the number of seconds in a day, so expirationDays * 8640 = expiration in seconds
            ///@dev if so, add the scheme bonus to the reward
            ///@dev if not, add the reward without the scheme bonus

            bool isValid = block.timestamp <=
                playerSchemes[current].purchasedDate +
                    schemes[playerSchemes[current].schemeId].expirationDays *
                    86400;

            if (playerSchemes[current].isAssigned && isValid) {
                if (
                    schemes[playerSchemes[current].schemeId].schemeType ==
                    ADDITION_SCHEME
                ) {
                    rewardWithSchemeBonus += schemes[
                        playerSchemes[current].schemeId
                    ].schemeValue;
                } else if (
                    schemes[playerSchemes[current].schemeId].schemeType ==
                    MULTIPLIER_SCHEME
                ) {
                    rewardAmount *= (
                        schemes[playerSchemes[current].schemeId].schemeValue
                    );
                } else if (
                    schemes[playerSchemes[current].schemeId].schemeType ==
                    PERCENTAGE_SCHEME
                ) {
                    rewardWithSchemeBonus += ((rewardAmount *
                        schemes[playerSchemes[current].schemeId].schemeValue) /
                        FEES_DIVISOR);
                }
            }
        }

        _transferTokens(
            dailyOperationsAddress,
            player,
            rewardWithSchemeBonus + rewardAmount,
            false
        );
        emit Rewarded(player, rewardWithSchemeBonus + rewardAmount, challendId);
    }
}
