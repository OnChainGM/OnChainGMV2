// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OnChainGMV2 is Initializable, UUPSUpgradeable, ERC721Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using Strings for uint256;
    using SafeERC20 for IERC20;

    // Custom Errors
    error TokenDoesNotExist();
    error AlreadySentGMToday();
    error IncorrectETHFee();
    error FeeTransferFailed();
    error InvalidAddress();
    error InvalidFee();
    error InvalidPercent();
    error CannotReferSelf();

    // State variables
    address public feeRecipient;
    uint256 public GM_FEE;
    uint256 public GM_FEE_WITH_REFERRAL;
    uint256 public REFERRAL_PERCENT;
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 private constant EPOCH_YEAR = 1970;
    uint256 private constant DAYS_1970_TO_2000 = 10957;
    uint256 private constant SECONDS_1970_TO_2000 = DAYS_1970_TO_2000 * SECONDS_PER_DAY;

    uint256 private _tokenIdCounter;
    mapping(address => uint256) public lastGMDay;
    mapping(uint256 => uint40) public tokenTimestamp;

    // Events
    event OnChainGMEvent(address indexed sender, address indexed referrer, uint256 indexed tokenId);
    event ReferralFailed(address indexed referrer, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() initializer public {
        __ERC721_init("GMCards", "GM");
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        
        // Set default fee recipient
        feeRecipient = 0x7500A83DF2aF99B2755c47B6B321a8217d876a85;
        _tokenIdCounter = 0;
        
        GM_FEE = 0.000029 ether;
        GM_FEE_WITH_REFERRAL = 0.00002465 ether;
        REFERRAL_PERCENT = 10;
    }

    /**
     * @dev Reinitializer for upgrades
     * @param version Version number
     */
    function reinitialize(uint64 version) external reinitializer(version) onlyOwner {
    }

    /**
     * @dev Check if token exists
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /**
     * @dev Handle referral payment
     */
    function _handleReferralPayment(address referrer, uint256 paymentAmount) private returns (uint256) {
        if (referrer == msg.sender || referrer == feeRecipient) {
            revert CannotReferSelf();
        }
        
        uint256 refAmount = (paymentAmount * REFERRAL_PERCENT) / 100;
        (bool refSuccess, ) = referrer.call{value: refAmount}("");
        if (!refSuccess) {
            emit ReferralFailed(referrer, refAmount);
            return 0;
        }
        return refAmount;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyOwner
        override
    {}

    /**
     * @dev Allow contract to receive ETH
     */
    receive() external payable {}

    function onChainGM(address referrer) external payable nonReentrant {
        _checkGMDay(msg.sender);
        uint256 requiredFee = referrer != address(0) ? GM_FEE_WITH_REFERRAL : GM_FEE;
        _checkETHFee(requiredFee);

        uint256 tokenId = _mintGM(msg.sender);
        emit OnChainGMEvent(msg.sender, referrer, tokenId);

        uint256 refAmount = 0;
        if (referrer != address(0)) {
            refAmount = _handleReferralPayment(referrer, msg.value);
        }

        _sendFee(msg.value - refAmount);
    }

    function _checkGMDay(address user) private {
        uint256 currentDay = block.timestamp / SECONDS_PER_DAY;
        if (lastGMDay[user] == currentDay) {
            revert AlreadySentGMToday();
        }
        lastGMDay[user] = currentDay;
    }

    function _checkETHFee(uint256 requiredFee) private view {
        if (msg.value != requiredFee) {
            revert IncorrectETHFee();
        }
    }

    function _mintGM(address user) private returns (uint256) {
        uint256 tokenId;
        unchecked {
            tokenId = _tokenIdCounter++;
        }
        tokenTimestamp[tokenId] = uint40(block.timestamp);
        _mint(user, tokenId);
        return tokenId;
    }

    function _sendFee(uint256 amount) private {
        (bool success, ) = feeRecipient.call{value: amount}("");
        if (!success) {
            revert FeeTransferFailed();
        }
    }

    function timeUntilNextGM(address user) external view returns (uint256) {
        uint256 currentDay = block.timestamp / SECONDS_PER_DAY;
        uint256 lastDay = lastGMDay[user];
        
        if (lastDay < currentDay || lastDay > currentDay) {
            return 0;
        }
        
        return ((currentDay + 1) * SECONDS_PER_DAY) - block.timestamp;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) {
            revert TokenDoesNotExist();
        }
        
        (uint256 month, uint256 day, uint256 year) = _parseTimestamp(uint256(tokenTimestamp[tokenId]));
        string memory date = _formatDateString(month, day, year);
        
        return _buildMetadata(tokenId, date);
    }

    function _buildMetadata(uint256 tokenId, string memory date) private pure returns (string memory) {
        string memory svg = _generateSVG(date);
        return string(abi.encodePacked(
            'data:application/json;base64,',
            Base64.encode(bytes(string(abi.encodePacked(
                '{"name":"GMCards #', tokenId.toString(),
                '","description":"OnChainGM Daily Card","image":"data:image/svg+xml;base64,',
                Base64.encode(bytes(svg)),
                '","attributes":[{"trait_type":"Date","value":"', date, '"}]}'
            ))))
        ));
    }

    function _generateSVG(string memory date) private pure returns (string memory) {
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="500" height="500" viewBox="0 0 500 500"><defs><filter id="a"><feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#000" flood-opacity=".4"/></filter></defs>',
            '<g filter="url(#a)">',
            '<path fill="#0a0a0a" stroke="#1a1a1a" d="M20 20h460v460H20z"/>',
            '<path stroke="#1a1a1a" d="M20 60h460"/>',
            '<text x="40" y="45" font-family="monospace" font-size="10" font-weight="600" fill="#4a4a4a" letter-spacing="2">PROOF OF GM</text>',
            '<path d="m250 150 43.3 25v50L250 250l-43.3-25v-50Z" fill="none" stroke="#fff" stroke-width="2"/>',
            '<text y="18" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,sans-serif" font-size="48" font-weight="700" fill="#fff" transform="translate(250 200)">GM</text>',
            '<text x="250" y="310" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,sans-serif" font-size="36" font-weight="600" fill="#fff" letter-spacing="4">OnChainGM</text>',
            '<path stroke="#333" d="M150 330h200"/>',
            '<text x="250" y="360" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,sans-serif" font-size="14" font-weight="400" fill="#666" letter-spacing="1">Your Daily Web3 Ritual</text>',
            '<g font-family="monospace" font-weight="600">',
            '<text x="80" y="420" font-size="10" fill="#4a4a4a" letter-spacing="1">CERTIFICATE</text>',
            '<text x="80" y="440" font-size="14" fill="#fff">#GMcards</text>',
            '<text x="280" y="420" font-size="10" fill="#4a4a4a" letter-spacing="1">MINTED</text>',
            '<text x="280" y="440" font-size="14" fill="#fff">', date, '</text>',
            '</g></g></svg>'
        ));
    }

    /**
     * @dev Parse timestamp to month, day, year
     */
    function _parseTimestamp(uint256 timestamp) private pure returns (uint256 month, uint256 day, uint256 year) {
        uint256 daysSinceEpoch = timestamp / SECONDS_PER_DAY;
        uint256 daysSince2000;
        
        if (timestamp >= SECONDS_1970_TO_2000) {
            daysSince2000 = (timestamp - SECONDS_1970_TO_2000) / SECONDS_PER_DAY;
            year = 2000;
            
            uint256 yearBlocks = daysSince2000 / 1461;
            year += yearBlocks * 4;
            daysSince2000 -= yearBlocks * 1461;
            
            while (daysSince2000 >= 365) {
                uint256 yearDays = ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)) ? 366 : 365;
                if (daysSince2000 < yearDays) break;
                daysSince2000 -= yearDays;
                year++;
            }
            daysSinceEpoch = daysSince2000;
        } else {
            year = EPOCH_YEAR;
            while (daysSinceEpoch >= 365) {
                uint256 yearDays = ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)) ? 366 : 365;
                if (daysSinceEpoch < yearDays) break;
                daysSinceEpoch -= yearDays;
                year++;
            }
        }
        
        uint256[12] memory daysInMonth = [uint256(31), 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        if ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)) {
            daysInMonth[1] = 29;
        }
        
        month = 1;
        for (uint256 i = 0; i < 12; i++) {
            if (daysSinceEpoch < daysInMonth[i]) {
                month = i + 1;
                day = daysSinceEpoch + 1;
                break;
            }
            daysSinceEpoch -= daysInMonth[i];
        }
    }

    /**
     * @dev Format date as MM.DD.YYYY
     */
    function _formatDateString(uint256 month, uint256 day, uint256 year) private pure returns (string memory) {
        bytes memory buffer = new bytes(10);
        buffer[0] = bytes1(uint8(48 + (month / 10)));
        buffer[1] = bytes1(uint8(48 + (month % 10)));
        buffer[2] = '.';
        buffer[3] = bytes1(uint8(48 + (day / 10)));
        buffer[4] = bytes1(uint8(48 + (day % 10)));
        buffer[5] = '.';
        buffer[6] = bytes1(uint8(48 + (year / 1000)));
        buffer[7] = bytes1(uint8(48 + ((year / 100) % 10)));
        buffer[8] = bytes1(uint8(48 + ((year / 10) % 10)));
        buffer[9] = bytes1(uint8(48 + (year % 10)));
        return string(buffer);
    }

    function totalSupply() public view returns (uint256) {
        return _tokenIdCounter;
    }

    function getTokenTimestamp(uint256 tokenId) public view returns (uint256) {
        if (!_exists(tokenId)) {
            revert TokenDoesNotExist();
        }
        return uint256(tokenTimestamp[tokenId]);
    }

    /**
     * @dev Set fee recipient address
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) {
            revert InvalidAddress();
        }
        feeRecipient = newRecipient;
    }

    /**
     * @dev Set GM fee amount
     */
    function setGMFee(uint256 newFee) external onlyOwner {
        if (newFee == 0 || newFee <= GM_FEE_WITH_REFERRAL) {
            revert InvalidFee();
        }
        GM_FEE = newFee;
    }

    /**
     * @dev Set GM fee with referral
     */
    function setGMFeeWithReferral(uint256 newFee) external onlyOwner {
        if (newFee == 0 || newFee >= GM_FEE) {
            revert InvalidFee();
        }
        GM_FEE_WITH_REFERRAL = newFee;
    }

    /**
     * @dev Set referral percentage
     */
    function setReferralPercent(uint256 newPercent) external onlyOwner {
        if (newPercent == 0 || newPercent >= 100) {
            revert InvalidPercent();
        }
        REFERRAL_PERCENT = newPercent;
    }

    /**
     * @dev Withdraw ETH accidentally sent to contract
     */
    function withdrawETH(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) {
            revert InvalidAddress();
        }
        
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert("No funds to withdraw");
        }
        
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        if (withdrawAmount > balance) {
            revert("Insufficient balance");
        }
        
        (bool success, ) = to.call{value: withdrawAmount}("");
        if (!success) {
            revert FeeTransferFailed();
        }
    }

    /**
     * @dev Emergency withdraw all ETH
     */
    function emergencyWithdraw() external onlyOwner nonReentrant {
        if (feeRecipient == address(0)) {
            revert InvalidAddress();
        }
        
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert("No funds to withdraw");
        }
        
        (bool success, ) = feeRecipient.call{value: balance}("");
        if (!success) {
            revert FeeTransferFailed();
        }
    }

    /**
     * @dev Get contract ETH balance
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Withdraw ERC20 tokens accidentally sent to contract
     */
    function withdrawERC20(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) {
            revert InvalidAddress();
        }
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) {
            revert("No tokens to withdraw");
        }
        
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        if (withdrawAmount > balance) {
            revert("Insufficient token balance");
        }
        
        IERC20(token).safeTransfer(to, withdrawAmount);
    }

    /**
     * @dev Get contract ERC20 token balance
     */
    function getContractTokenBalance(address token) external view returns (uint256) {
        if (token == address(0)) {
            revert InvalidAddress();
        }
        return IERC20(token).balanceOf(address(this));
    }

    // Override transfer functions to make NFTs non-transferable
    function transferFrom(address, address, uint256) public pure override {
        revert("NFT transfer is disabled - GMCards are non-transferable");
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert("NFT transfer is disabled - GMCards are non-transferable");
    }

    function approve(address, uint256) public pure override {
        revert("NFT approval is disabled - GMCards are non-transferable");
    }

    function setApprovalForAll(address, bool) public pure override {
        revert("NFT approval is disabled - GMCards are non-transferable");
    }

    /**
     * @dev Storage gap for upgradeability
     */
    uint256[50] private __gap;
}
