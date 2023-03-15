// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./library/TransferHelper.sol";

// import "hardhat/console.sol";

contract StakingConfig is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMathUpgradeable for uint256;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;
    uint256 public epochLength; //每个rebase周期的区块个数

    //rebase通胀率的配置信息
    struct RebaseRateInfo {
        uint256 id; //配置的编号
        uint256 rebaseRate; //通胀率，实际通胀率=rate/1000000
        uint256 burnNectarTokenRate; //消耗NectarToken占质押openToken的数量的比例，如burnNectarTokenRate=50，则需要消耗nectarToken数量=openToken质押数量*(50/1000)
    }
    EnumerableSetUpgradeable.UintSet private rebaseRateInfoIds; //rebase收益率配置的id列表
    mapping(uint256 => RebaseRateInfo) public rebaseRateInfoById; //mapping(收益率配置ID=>RebaseRateInfo)
    uint256 public rebaseRateInfoMaxId; //收益率配置的Id,大于0才有效
    uint256 public defaultRebaseRateInfoId; //默认的rebase通胀率配置id

    //openToken质押区块个数配置
    struct StakeBlockCountInfo {
        uint256 blockCount; //质押的区块数
        bool isOpen; //是否允许选择该区块
    }
    mapping(uint256 => StakeBlockCountInfo) public stakeBlockCountInfoOf; //mapping(质押区块数=>StakeBlockCountInfo)
    EnumerableSetUpgradeable.UintSet private openTokenStakeBlocks; //openToken质押区块个数列表

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 _epochLength) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        epochLength = _epochLength;
    }

    /**
     * @notice  配置收益率
     * @param _config.id 配置的id，为空则新增，不为空则更新
     * @param _config.rebaseRate 通胀率，即每个rebase的资金增长率
     * @param _config.burnNectarTokenRate 消耗NectarToken的比例，即消耗的nectarToken占质押的openToken本金的多少比例
     */
    function setRebaseRateInfo(RebaseRateInfo calldata _config)
        external
        onlyOwner
    {
        //当前暂不开放修改配置，因为涉及到后续的收益计算。
        require(_config.id == 0, "Modification is not allowed");
        require(_config.burnNectarTokenRate < 1000, "burnNectarTokenRate too large"); //分母是1000
        require(_config.rebaseRate < 1000000, "rebaseRate too large"); //分母是1000000

        //记录配置信息
        rebaseRateInfoMaxId = rebaseRateInfoMaxId + 1;
        rebaseRateInfoIds.add(rebaseRateInfoMaxId);
        rebaseRateInfoById[rebaseRateInfoMaxId] = RebaseRateInfo({
            id: rebaseRateInfoMaxId,
            rebaseRate: _config.rebaseRate,
            burnNectarTokenRate: _config.burnNectarTokenRate
        });
    }

    /**
     * @notice  查询当前所有rebase配置
     */
    function getAllRebaseRateInfo()
        external
        view
        returns (uint256 size_, RebaseRateInfo[] memory result_)
    {
        size_ = rebaseRateInfoIds.length();
        result_ = new RebaseRateInfo[](size_);
        if (size_ == 0) return (size_, result_);

        for (uint256 i = 0; i < size_; i++) {
            uint256 id = rebaseRateInfoIds.at(i);
            result_[i] = rebaseRateInfoById[id];
        }
    }

    /**
     * @notice  查询当前所有rebase配置的ID
     */
    function getAllRebaseRateInfoIds()
        external
        view
        returns (uint256 size_, uint256[] memory result_)
    {
        size_ = rebaseRateInfoIds.length();
        result_ = new uint256[](size_);
        if (size_ == 0) return (size_, result_);

        for (uint256 i = 0; i < size_; i++) {
            result_[i] = rebaseRateInfoIds.at(i);
        }
    }

    /**
     * @notice  配置质押区块数的信息（因为涉及到历史数据，因此只能新增或停用，不可删除）
     * @param _config.blockCount 质押区块的个数
     * @param _config.isOpen 配置是否开启  true:对外开放， false: 不对外开放
     */
    function setStakeBlockCountInfo(StakeBlockCountInfo calldata _config)
        external
        onlyOwner
    {
        //区块个数必须是rebase周期的整倍数
        require(_config.blockCount.mod(epochLength) == 0, "invalid blockCount");

        //保存配置信息
        stakeBlockCountInfoOf[_config.blockCount] = _config;
        if (_config.isOpen) openTokenStakeBlocks.add(_config.blockCount);
    }

    /**
     * @notice  查询当前所有质押区块数配置
     */
    function getAllStakeBlockCountInfo()
        external
        view
        returns (uint256 size_, StakeBlockCountInfo[] memory result_)
    {
        size_ = openTokenStakeBlocks.length();
        result_ = new StakeBlockCountInfo[](size_);
        if (size_ == 0) return (size_, result_);

        for (uint256 i = 0; i < size_; i++) {
            uint256 id = openTokenStakeBlocks.at(i);
            result_[i] = stakeBlockCountInfoOf[id];
        }
    }

    // withdraw token by owner
    function withdrawToken(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOwner nonReentrant {
        if (address(0) == _token) {
            uint256 amount = _amount > 0 ? _amount : address(this).balance;
            TransferHelper.safeTransferETH(_to, amount);
        } else {
            uint256 amount = _amount > 0
                ? _amount
                : IERC20Upgradeable(_token).balanceOf(address(this));
            TransferHelper.safeTransfer(_token, _to, amount);
        }
    }

    /**
     * @notice  设置uint256类型的参数
     * @param _type 配置类型
     * @param _value 配置值
     */
    function setUintValue(uint256 _type, uint256 _value) external onlyOwner {
        if (_type == 0) {
            require(defaultRebaseRateInfoId == 0, "already init");
            require(rebaseRateInfoIds.contains(_value), "invalid rateInfoId");
            defaultRebaseRateInfoId = _value; //默认的rebase收益率ID
        }
    }

    /**
     * @notice  检查收益率的配置ID是否有效
     * @param _rateInfoId 质押收益率配置的ID
     */
    function isRebaseRateInfoIdValid(uint256 _rateInfoId)
        public
        view
        returns (bool)
    {
        return rebaseRateInfoIds.contains(_rateInfoId);
    }

    /**
     * @notice  根据ID查询收益率的配置详情
     * @param _rateInfoId 质押收益率配置的ID
     */
    function getRebaseRateInfoById(uint256 _rateInfoId)
        public
        view
        returns (
            uint256 id,
            uint256 rebaseRate,
            uint256 burnNectarTokenRate
        )
    {
        RebaseRateInfo memory rateInfo = rebaseRateInfoById[_rateInfoId];
        return (rateInfo.id, rateInfo.rebaseRate, rateInfo.burnNectarTokenRate);
    }

    /**
     * @notice  判断在质押时长是否被允许
     * @param _blockCount 质押的区块个数
     */
    function isBlockCountSupportStake(uint256 _blockCount)
        public
        view
        returns (bool)
    {
        return stakeBlockCountInfoOf[_blockCount].isOpen;
    }

    /**
     * @notice  查询质押时长配置的所有记录--针对合约调用
     */
    function getAllBlockCountConfig()
        public
        view
        returns (
            uint256 size_,
            uint256[] memory blockCountList_,
            bool[] memory statusList_
        )
    {
        size_ = openTokenStakeBlocks.length();
        blockCountList_ = new uint256[](size_);
        statusList_ = new bool[](size_);
        for (uint256 i = 0; i < size_; i++) {
            uint256 blockCount = openTokenStakeBlocks.at(i);
            blockCountList_[i] = blockCount;
            statusList_[i] = stakeBlockCountInfoOf[blockCount].isOpen;
        }
        return (size_, blockCountList_, statusList_);
    }
}
