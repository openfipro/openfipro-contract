// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.2;

import "./interface/IERC20.sol";
import "./interface/IOpenTokenERC20.sol";
import "./interface/INectarTokenFarmForInvter.sol";
import "./interface/INectarTokenFarmForStaker.sol";
import "./interface/IOpenTokenFarmForInvter.sol";
import "./interface/IStakingRewardRelease.sol";
import "./interface/IPresaleRelease.sol";
import "./interface/ITreasury.sol";
import "./interface/IStakingConfig.sol";
import "./interface/IRebaseOpenToken.sol";
import "./library/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

// import "hardhat/console.sol";
//注意，新合约需要注意初期数据混乱问题，如首个rebase前的质押数据
contract StakingContract is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    uint256 public constant ONE_AI_TOKEN = 1 * 10**9;
    address public OpenToken;
    address public sOpenToken;
    address public nectarTokenFarmForInvter;
    address public nectarTokenFarmForStaker;
    address public stakingRewardRelease;
    address public openTokenFarmForInviter;
    address public presaleRelease;
    address public treasury;
    address public stakingConfigContract;
    address public nectarTokenAddress; //NectarToken代币合约地址

    struct Epoch {
        uint256 length;
        uint256 latestEndBlock;
        uint256 nextEndBlock;
    }
    Epoch public epoch;

    mapping(address => uint256) public principalByAddress; //mapping(用户钱包地址=>质押的本金);

    //rebase重要的信息，每个通胀率配置都对应有一个rebaseInfo信息
    struct RebaseEpochInfo {
        uint256 rebaseRateInfoId; //rebase通胀率的配置信息的Id
        uint256 index; //增长指数，每次rebase后都按当前最新的通胀率增长。多个rebase之后，可用于计算用户的rebase收益。（需要注意：首次赋值后不可再人工修改，否则影响收益计算）
        uint256 principalTotal; //质押的本金总额
        uint256 highRateRebasingAmountTotal; //高收益率下正参与rebase的资金总额（即未到期的质押的总本金+未到期的总收益）
        uint256 defaultRateRebasingAmountTotal; //默认收益率下正参与rebase的资金总额（即到期后的质押的总本金+总收益）
    }
    //根据收益率配置的ID匹配当前最新的rebase数据详情  mapping(收益率配置ID=>RebaseEpochInfo)
    mapping(uint256 => RebaseEpochInfo) public rebaseEpochInfoOf;
    //根据【收益率配置的ID】和【reabse触发的区块】匹配当时的rebase数据详情 mapping(收益率配置ID=>mapping(rebase发生区块=>RebaseEpochInfo))
    mapping(uint256 => mapping(uint256 => RebaseEpochInfo))
        public rebaseEpochHistoryInfoOf;

    //质押到期的本金总额，到期后就不再有高收益，回归到最低的默认收益
    struct PrincipalExpireInfo {
        uint256 stakedIndex; //保存时的rebase周期的index,用于计算本金到期后,有多少资金回归到默认的最低的rebase收益率
        uint256 expirePrincipal; //将到期的本金总额
    }
    // mapping(rebase已发生或将来发生的区块=>mapping(rebaseRateInfoId=>质押时选择的区块数=>PrincipalExpireInfo))
    mapping(uint256 => mapping(uint256 => mapping(uint256 => PrincipalExpireInfo)))
        public principalExpireInfoOf;

    //用户的高收益质押信息
    struct UserStakeInfo {
        uint256 firstTimestamp; //首次保存的时间戳
        uint256 savedTimestamp; //数据最近一次保存时的时间戳
        uint256 savedBlock; //数据最近一次保存时的区块
        uint256 savedEpochBlock; //数据最近一次保存时，最近一个已发生的rebase区块
        uint256 minRebaseRateStartBlock; //在哪个区块之后回归默认的最低rebase收益
        uint256 savedIndex; //数据保存时的rebase指数值,用于在多个rebase后计算收益
        uint256 principalAmount; //本条记录的OpenToken本金数量
        uint256 rebasingAmount; //正在参与rebase的资金数量
        uint256 rebaseRateInfoId; //对应的收益率配置的id,用于后续计算收益时，定位到对应的index
    }
    //mapping(用户钱包地址=>mapping(记录保存的时间戳=>UserStakeInfo))
    mapping(address => mapping(uint256 => UserStakeInfo))
        public userStakeInfoOf;
    //mapping(用户钱包地址=> 所有质押数据的时间戳集合)
    mapping(address => EnumerableSetUpgradeable.UintSet)
        private userStakeTimesByAddress;
    bool public isMintRebaseRewardOpen; //是否铸造rebase收益(如果false，则执行rebase,但不会铸币，用户的sOpenToken有增长)
    uint256 public rebaseRewardDebt; //铸币欠款，归还时需要清零

    //event
    event StakeOpenToken(
        uint256 amount,
        address receipt,
        uint256 rebaseRateInfoId,
        uint256 stakeBlocks
    );
    event Unstake(uint256 firstStakeTime, uint256 amount);
    event Rebase(uint256 profit);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _openToken,
        address _sOpenToken,
        address _openTokenFarmForInviter,
        address _nectarTokenFarmForInvter,
        address _nectarTokenFarmForStaker,
        address _stakingRewardRelease,
        address _presaleRelease,
        address _treasury,
        address _stakingConfig,
        address _nectarTokenAddress,
        uint256 _epochLength
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        require(_openToken != address(0));
        OpenToken = _openToken;
        require(_sOpenToken != address(0));
        sOpenToken = _sOpenToken;
        require(_openTokenFarmForInviter != address(0));
        openTokenFarmForInviter = _openTokenFarmForInviter;
        require(_nectarTokenFarmForInvter != address(0));
        nectarTokenFarmForInvter = _nectarTokenFarmForInvter;
        require(_nectarTokenFarmForStaker != address(0));
        nectarTokenFarmForStaker = _nectarTokenFarmForStaker;
        require(_stakingRewardRelease != address(0));
        stakingRewardRelease = _stakingRewardRelease;
        require(_presaleRelease != address(0));
        presaleRelease = _presaleRelease;
        require(_treasury != address(0));
        treasury = _treasury;
        require(_stakingConfig != address(0));
        stakingConfigContract = _stakingConfig;
        require(_nectarTokenAddress != address(0));
        nectarTokenAddress = _nectarTokenAddress;

        uint256 firstBlock = block.number;
        epoch = Epoch({
            length: _epochLength,
            latestEndBlock: firstBlock,
            nextEndBlock: firstBlock.add(_epochLength)
        });
    }

    /**
     * @notice  质押OpenToken
     * @param _amount 质押金额
     * @param _receipt 质押数据记录入该钱包地址
     * @param _rebaseRateInfoId 本次质押选择的收益率配置的id
     * @param _stakeBlocks 该质押数据的高收益率在多少个区块内有效
     */
    function stakeOpenToken(
        uint256 _amount,
        address _receipt,
        uint256 _rebaseRateInfoId,
        uint256 _stakeBlocks
    ) external nonReentrant {
        require(_amount > 0, "check amount");
        //触发rebase
        _rebase();
        //质押具体逻辑
        _stake(
            msg.sender,
            _receipt,
            _rebaseRateInfoId,
            _amount,
            _amount,
            _stakeBlocks,
            true
        );
    }

    /**
     * @notice  取消质押OpenToken
     * @param _firstStakeTime 首次质押时的时间戳，用于确定操作哪条数据
     */
    function unstake(uint256 _firstStakeTime) external nonReentrant {
        _rebase();
        _unstake(msg.sender, _firstStakeTime, true);
    }

    /**
     * @notice  查询收益率当前对应的index
     */
    function index(uint256 _rateInfoId) public view returns (uint256) {
        return rebaseEpochInfoOf[_rateInfoId].index;
    }

    /**
     * @notice  触发铸币
     */
    function _rebase() private {
        if (epoch.nextEndBlock <= block.number) {
            (
                uint256 rateConfigSize,
                uint256[] memory rateIdList
            ) = IStakingConfig(stakingConfigContract).getAllRebaseRateInfoIds();

            //遍历收益率配置列表
            uint256 distributeTotal = 0;
            for (uint256 i = 0; i < rateConfigSize; i++) {
                uint256 rateId = rateIdList[i];
                uint256 distribute = _rebaseByRateInfoId(rateId);
                distributeTotal += distribute;
            }

            //铸造OpenToken
            if (distributeTotal > 0) {
                if (isMintRebaseRewardOpen) {
                    ITreasury(treasury).mintRewards(
                        address(this),
                        distributeTotal
                    );
                } else {
                    rebaseRewardDebt += distributeTotal;
                }

                IRebaseOpenToken(sOpenToken).increaseTotalSupply(
                    distributeTotal,
                    address(0)
                );
            }

            epoch.latestEndBlock = epoch.nextEndBlock;
            epoch.nextEndBlock += epoch.length;
            // emit Rebase(realDistribute, epoch.number);
            emit Rebase(distributeTotal);
        }
    }

    /**
     * @notice  计算收益率对应的rebase数据
     * @param _rateInfoId rebase收益率配置的ID
     */
    function _rebaseByRateInfoId(uint256 _rateInfoId)
        private
        returns (uint256 rateDistributeTotal_)
    {
        //================================
        //====先rebase分红，再处理到期的数据
        //================================

        //如果index为0，则表明还没有任何质押数据
        RebaseEpochInfo storage epochInfo = rebaseEpochInfoOf[_rateInfoId];
        if (epochInfo.index == 0) return 0;

        //判断rebase资金是否足够，不够就跳过rebase
        (, , bool isEnough) = isReservesEnoughToNextRebase();
        if (isEnough) {
            //根据rateInfoId,计算rebase分红数据
            (
                uint256 newIndex_,
                uint256 newHighRebasing_,
                uint256 newDefaultRebasing_,
                uint256 distribute_,
                uint256 highRateDistribute_
            ) = _calculateDistributeByRateInfoId(_rateInfoId);
            rateDistributeTotal_ = distribute_;

            //记录rebase后的数据
            epochInfo.index = newIndex_;
            epochInfo.highRateRebasingAmountTotal = newHighRebasing_;
            epochInfo.defaultRateRebasingAmountTotal = newDefaultRebasing_;
        }

        //记录一条历史记录
        rebaseEpochHistoryInfoOf[_rateInfoId][block.number] = RebaseEpochInfo({
            rebaseRateInfoId: epochInfo.rebaseRateInfoId,
            index: epochInfo.index,
            principalTotal: epochInfo.principalTotal,
            highRateRebasingAmountTotal: epochInfo.highRateRebasingAmountTotal,
            defaultRateRebasingAmountTotal: epochInfo
                .defaultRateRebasingAmountTotal
        });

        //本次rebase后，到期的高收益的资金转移到低收益率的池子（根据质押区块数处理到期的资金）
        (
            uint256 blockCountConfigSize,
            uint256[] memory blockCountConfigList,
            bool[] memory blockCountConfigStatusList
        ) = IStakingConfig(stakingConfigContract).getAllBlockCountConfig();

        //遍历质押时长的配置列表
        for (uint256 i = 0; i < blockCountConfigSize; i++) {
            uint256 blockCount = blockCountConfigList[i];

            PrincipalExpireInfo
                memory principalExpireInfo = principalExpireInfoOf[
                    epoch.nextEndBlock
                ][_rateInfoId][blockCount];
            if (principalExpireInfo.expirePrincipal > 0) {
                //现在需要停止高收益率rebase的资金(本金+收益)总额是多少
                uint256 willExpireRebasing = _calculateCurrentRebasingAmount(
                    principalExpireInfo.expirePrincipal,
                    principalExpireInfo.stakedIndex,
                    epochInfo.index
                );

                //将这些已到期的资金（本金+收益），转移到地收益率资金池子中
                epochInfo.highRateRebasingAmountTotal -= willExpireRebasing;
                epochInfo.defaultRateRebasingAmountTotal += willExpireRebasing;
            }
        }
    }

    /**
     * @notice  根据rebase收益率的ID,查询
     * @param _rateInfoId rebase收益率配置的ID
     * @return newIndex_ rebase后新的index值
     * @return newHighRebasing_ rebase后下次可以参与高收益rebase的资金总数量
     * @return newDefaultRebasing_ rebase后下次可以参与低收益rebase的资金总数量
     * @return distributeTotal_ 本次rebase将要分红的总数量
     * @return highRateDistribute_ 本次rebase分红中，高收益的分红占有数量
     */
    function _calculateDistributeByRateInfoId(uint256 _rateInfoId)
        private
        view
        returns (
            uint256 newIndex_,
            uint256 newHighRebasing_,
            uint256 newDefaultRebasing_,
            uint256 distributeTotal_,
            uint256 highRateDistribute_
        )
    {
        (, uint256 rebaseRate, ) = IStakingConfig(stakingConfigContract)
            .getRebaseRateInfoById(_rateInfoId);
        (, uint256 defaultRate, ) = IStakingConfig(stakingConfigContract)
            .getRebaseRateInfoById(defaultRebaseRateInfoId());
        // 收益率配置Id对应当前最新的rebase信息
        RebaseEpochInfo memory epochInfo = rebaseEpochInfoOf[_rateInfoId];
        uint256 oldHighRateRebasing = epochInfo.highRateRebasingAmountTotal;
        uint256 newHighRateRebasing = oldHighRateRebasing;
        uint256 oldDefaultRateRebasing = epochInfo
            .defaultRateRebasingAmountTotal;
        uint256 newDefaultRateRebasing = oldDefaultRateRebasing;
        uint256 oldIndex = epochInfo.index;
        uint256 newIndex = oldIndex;

        // 计算本次rebase后的相关数据变化值
        //newRebasing = oldRebasing+oldRebasing*rate/1000000
        newDefaultRateRebasing = oldDefaultRateRebasing.add(
            defaultRate.mul(oldDefaultRateRebasing).div(1000000)
        );
        if (_rateInfoId == defaultRebaseRateInfoId()) {
            //newIndex = index+index*rate/1000000
            newIndex = oldIndex.add(defaultRate.mul(oldIndex).div(1000000));
        } else {
            //newIndex = index+index*rate/1000000
            newIndex = oldIndex.add(rebaseRate.mul(oldIndex).div(1000000));
            //newRebasing = oldRebasing+oldRebasing*rate/1000000
            newHighRateRebasing = oldHighRateRebasing.add(
                rebaseRate.mul(oldHighRateRebasing).div(1000000)
            );
        }

        highRateDistribute_ = newHighRateRebasing.sub(oldHighRateRebasing);
        uint256 defaultRateDistribute = newDefaultRateRebasing.sub(
            oldDefaultRateRebasing
        );
        distributeTotal_ = defaultRateDistribute.add(highRateDistribute_);

        return (
            newIndex,
            newHighRateRebasing,
            newDefaultRateRebasing,
            distributeTotal_,
            highRateDistribute_
        );
    }

    /**
     * @notice  变更用户质押的本金总额
     * @param _staker 用户的钱包地址
     * @param _increaseAmount 增加的本金数量
     * @param _decreaseAmount 减少的本金数量
     */
    function _changeStakeAmount(
        address _staker,
        uint256 _increaseAmount,
        uint256 _decreaseAmount
    ) private {
        uint256 beforeAmount = principalByAddress[_staker];
        if (_increaseAmount > 0) {
            principalByAddress[_staker] = beforeAmount.add(_increaseAmount);
        } else if (_decreaseAmount > 0) {
            principalByAddress[_staker] = beforeAmount.sub(_decreaseAmount);
        }

        uint256 afterAmount = principalByAddress[_staker];
        if (nectarTokenFarmForInvter != address(0)) {
            INectarTokenFarmForInvter(nectarTokenFarmForInvter)
                .changeStakeAmount(_staker, afterAmount);
        }
        if (nectarTokenFarmForStaker != address(0)) {
            INectarTokenFarmForStaker(nectarTokenFarmForStaker)
                .changeStakeAmount(_staker, afterAmount);
        }
        if (openTokenFarmForInviter != address(0)) {
            IOpenTokenFarmForInvter(openTokenFarmForInviter).changeStakeAmount(
                _staker,
                afterAmount
            );
        }

        if (presaleRelease != address(0)) {
            IPresaleRelease(presaleRelease).changeStakeAmount(
                _staker,
                afterAmount
            );
        }
    }

    function _sendOpenTokenReward(address _receiptor, uint256 _rewardAmount)
        private
    {
        if (_rewardAmount == 0) return;
        if (stakingRewardRelease != address(0)) {
            IStakingRewardRelease(stakingRewardRelease).addReward(
                _receiptor,
                _rewardAmount
            );

            IERC20(OpenToken).safeTransfer(stakingRewardRelease, _rewardAmount);
        } else {
            IERC20(OpenToken).safeTransfer(_receiptor, _rewardAmount);
        }
    }

    function contractBalance() public view returns (uint256) {
        return IERC20(OpenToken).balanceOf(address(this));
    }

    function getStakingAmount(address _addr)
        external
        view
        returns (uint256 stakingAmount_)
    {
        return principalByAddress[_addr];
    }

    /**
     * @notice  配置合约信息
     * @param _contract 合约地址
     * @param _type 合约类型(后续可持续追加)
     */
    function setAddress(uint256 _type, address _contract) external onlyOwner {
        if (_type == 0) {
            OpenToken = _contract;
        } else if (_type == 1) {
            sOpenToken = _contract;
        } else if (_type == 2) {
            nectarTokenFarmForInvter = _contract;
        } else if (_type == 3) {
            nectarTokenFarmForStaker = _contract;
        } else if (_type == 4) {
            stakingRewardRelease = _contract;
        } else if (_type == 5) {
            openTokenFarmForInviter = _contract;
        } else if (_type == 6) {
            presaleRelease = _contract;
        } else if (_type == 7) {
            treasury = _contract;
        } else if (_type == 8) {
            stakingConfigContract = _contract;
        } else if (_type == 9) {
            nectarTokenAddress = _contract;
        }
    }

    /**
     * @notice  设置Bool类型的参数
     * @param _type 配置类型
     * @param _value 配置值
     */
    function setBoolValue(uint256 _type, bool _value) external onlyOwner {
        if (_type == 0) {
            isMintRebaseRewardOpen = _value; //是否铸造rebase收益
        } 
    }

    /**
     * @notice  销毁NectarToken获取更高的rebase收益
     * @param _firstStakedTime 记录首次保存的时间戳，用于确定操作哪条数据
     * @param _targetRateInfoId rebase通胀率的配置信息的Id
     */
    function burnNectarTokenForHigherRebaseReward(
        uint256 _firstStakedTime,
        uint256 _targetRateInfoId,
        uint256 _stakeBlocks
    ) external nonReentrant {
        //先触发rebase
        _rebase();
        //检查数据源是否有效
        UserStakeInfo storage stakeInfo = userStakeInfoOf[msg.sender][
            _firstStakedTime
        ];
        require(stakeInfo.principalAmount > 0, "principalAmount not enough");
        //只支持转换最低收益率的数据
        require(
            stakeInfo.rebaseRateInfoId == defaultRebaseRateInfoId(),
            "the principal is not supported"
        );

        //检查收益率配置的ID
        require(
            IStakingConfig(stakingConfigContract).isRebaseRateInfoIdValid(
                _targetRateInfoId
            ),
            "invalid _targetRateInfoId"
        );

        //检查质押的区块个数
        require(
            IStakingConfig(stakingConfigContract).isBlockCountSupportStake(
                _stakeBlocks
            ),
            "invalid _stakeBlocks"
        );
        //解压低收益
        (, uint256 principal, ) = _unstake(msg.sender, _firstStakedTime, false);
        //增加一条质押记录
        _stake(
            msg.sender,
            msg.sender,
            _targetRateInfoId,
            principal,
            0,
            _stakeBlocks,
            true
        );

        // emit  BurnNectarTokenForHigherRebaseReward( _amount, _targetRateInfoId, _stakeBlocks);
    }

    /**
     * @notice 分页查询当前的质押记录(当然，已解压的不包含在内)
     * @param _staker 用户的钱包地址
     * @param _start start index
     * @param _size query size
     */
    function getStakeInfoByPage(
        address _staker,
        uint256 _start,
        uint256 _size
    )
        external
        view
        returns (
            uint256 resultSize_,
            UserStakeInfo[] memory resultArr_,
            uint256[] memory nextRewardArray_,
            uint256[] memory rateArray_
        )
    {
        require(_size < 50, "size too large");
        resultArr_ = new UserStakeInfo[](0);
        nextRewardArray_ = new uint256[](0);
        rateArray_ = new uint256[](0);
        if (userStakeTimesByAddress[_staker].length() == 0) {
            return (0, resultArr_, nextRewardArray_, rateArray_);
        }
        uint256 largestIndex = userStakeTimesByAddress[_staker].length().sub(1);
        require(_start <= largestIndex, "start too large");
        uint256 endIndex = _start.add(_size);

        uint256 endIndexFinal = endIndex > largestIndex
            ? largestIndex
            : endIndex;

        resultSize_ = endIndexFinal.sub(_start).add(1);

        (, uint256 defaultRebaseRate, ) = IStakingConfig(stakingConfigContract)
            .getRebaseRateInfoById(defaultRebaseRateInfoId());

        {
            UserStakeInfo[] memory resultArr = new UserStakeInfo[](resultSize_);
            uint256[] memory nextRewardArray = new uint256[](resultSize_);
            uint256[] memory rateArray = new uint256[](resultSize_);
            address staker = _staker;
            uint256 start = _start;
            for (uint256 i = 0; i < resultSize_; i++) {
                uint256 time = userStakeTimesByAddress[staker].at(start);
                UserStakeInfo memory stakeInfo = userStakeInfoOf[staker][time];

                //计算rebase后的总额、本金、收益
                (
                    uint256 currentRebasingAmount_,
                    uint256 principal_,
                    uint256 reward_
                ) = getCurrentRebasingAmount(staker, stakeInfo.firstTimestamp);
                stakeInfo.rebasingAmount = currentRebasingAmount_;
                resultArr[i] = stakeInfo;

                uint256 minRebaseRateStartBlock = stakeInfo
                    .minRebaseRateStartBlock;
                if (
                    minRebaseRateStartBlock < epoch.nextEndBlock ||
                    stakeInfo.savedEpochBlock == minRebaseRateStartBlock
                ) {
                    rateArray[i] = defaultRebaseRate;
                } else {
                    (, uint256 rebaseRate, ) = IStakingConfig(
                        stakingConfigContract
                    ).getRebaseRateInfoById(stakeInfo.rebaseRateInfoId);
                    rateArray[i] = rebaseRate;
                }

                nextRewardArray[i] = currentRebasingAmount_
                    .mul(rateArray[i])
                    .div(1000000);

                start = start.add(1);
            }

            return (resultSize_, resultArr, nextRewardArray, rateArray);
        }
    }

    /**
     * @notice 计算用户当前参与rebase的资金
     * @param _staker 用户的钱包地址
     * @param _firstStakedTime 质押记录首次保存的时间戳，用于定位质押数据
     */
    function getCurrentRebasingAmount(address _staker, uint256 _firstStakedTime)
        public
        view
        returns (
            uint256 currentRebasingAmount_,
            uint256 principal_,
            uint256 reward_
        )
    {
        UserStakeInfo memory stakeInfo = userStakeInfoOf[_staker][
            _firstStakedTime
        ];

        RebaseEpochInfo memory rateEpochInfo = rebaseEpochInfoOf[
            stakeInfo.rebaseRateInfoId
        ];

        (
            uint256 currentRebasing,
            uint256 principal,
            uint256 reward
        ) = _calculateRebasing(
                _staker,
                _firstStakedTime,
                epoch.latestEndBlock,
                rateEpochInfo.index
            );
        return (currentRebasing, principal, reward);
    }

    /**
     * @notice 计算用户当前参与rebase的资金
     * @param _staker 用户的钱包地址
     * @param _firstStakedTime 质押记录首次保存的时间戳，用于定位质押数据
     * @param _rebaseBlock rebase要发生的区块(必须跟_toIndex相对应，不可乱写)
     * @param _toIndex 计算截止的index(必须跟_rebaseBlock相对应，不可乱写)
     */
    function _calculateRebasing(
        address _staker,
        uint256 _firstStakedTime,
        uint256 _rebaseBlock,
        uint256 _toIndex
    )
        private
        view
        returns (
            uint256 currentRebasingAmount_,
            uint256 principal_,
            uint256 reward_
        )
    {
        UserStakeInfo memory stakeInfo = userStakeInfoOf[_staker][
            _firstStakedTime
        ];

        uint256 currentRebasing = stakeInfo.rebasingAmount;

        uint256 savedIndex = stakeInfo.savedIndex;
        if (savedIndex == 0)
            return (currentRebasing, stakeInfo.principalAmount, 0);

        //当前本金和收益总额= 资金经过高收益率的rebase后的余额，再经过低收益率的rebase后得到的余额
        //判断是否已由高收益率切换到低收益率
        uint256 minRebaseRateStartBlock = stakeInfo.minRebaseRateStartBlock;
        if (
            stakeInfo.savedEpochBlock == minRebaseRateStartBlock ||
            minRebaseRateStartBlock >= _rebaseBlock
        ) {
            //一直是低收益，或者高收益率未到期
            currentRebasing = _calculateCurrentRebasingAmount(
                stakeInfo.rebasingAmount,
                stakeInfo.savedIndex,
                _toIndex
            );
        } else {
            //===高收益率已到期===
            //计算高收益率的收益
            uint256 highRebaseRateEndIndex = rebaseEpochHistoryInfoOf[
                stakeInfo.rebaseRateInfoId
            ][stakeInfo.minRebaseRateStartBlock].index;

            //计算高收益率的rebase收益+本金总额
            uint256 rebasingAmountTmp = _calculateCurrentRebasingAmount(
                stakeInfo.rebasingAmount,
                stakeInfo.savedIndex,
                highRebaseRateEndIndex
            );

            //计算低收益率的rebase收益+本金总额
            uint256 minRebaseRateStartIndex = rebaseEpochHistoryInfoOf[
                defaultRebaseRateInfoId()
            ][stakeInfo.minRebaseRateStartBlock].index;
            currentRebasing = _calculateCurrentRebasingAmount(
                rebasingAmountTmp,
                minRebaseRateStartIndex,
                _toIndex
            );
        }

        uint256 rewardAmount = currentRebasing.sub(stakeInfo.principalAmount);
        return (currentRebasing, stakeInfo.principalAmount, rewardAmount);
    }

    /**
     * @notice 根据质押金额和两个index计算当前有多少资金参与rebase(包含本金和收益)
     * @notice 计算公式：oldIndex/newIndex=oldAmount/newAmount  =>  newAmount = oldAmount/(oldIndex/newIndex)=oldAmount*newIndex/oldIndex
     * @param _rebasingAmount 参与rebase的起始资金
     * @param _fromIndex 起始的index
     * @param _toIndex 截止的index
     */
    function _calculateCurrentRebasingAmount(
        uint256 _rebasingAmount,
        uint256 _fromIndex,
        uint256 _toIndex
    ) private view returns (uint256) {
        //多个rebase后的收益加本金总额= oldAmount*newIndex/oldIndex
        uint256 rebasingAmountCurrent = _rebasingAmount.mul(_toIndex).div(
            _fromIndex
        );
        return rebasingAmountCurrent;
    }

    /**
     * @notice 获取用户当前有多少资金参与rebase(包含本金和收益,还有从旧版本staking迁移过来的收益)--可以用这个查sOpenToken余额
     * @param _staker 用户钱包地址
     */
    function getUserSOpenTokenTotal(address _staker)
        public
        view
        returns (uint256)
    {
        uint256 length = userStakeTimesByAddress[_staker].length();
        if (length == 0) return 0;
        uint256 currentRebasing = 0;
        for (uint256 i = 0; i < length; i++) {
            uint256 timestamp = userStakeTimesByAddress[_staker].at(i);
            //计算rebase后的总额、本金、收益
            (uint256 currentRebasingAmount_, , ) = getCurrentRebasingAmount(
                _staker,
                timestamp
            );

            currentRebasing = currentRebasing.add(currentRebasingAmount_);
        }
        return currentRebasing;
    }

    /**
     * @notice 解除质押
     * @param _staker 用户钱包地址
     * @param _firstStakedTime 质押记录首次保存的时间戳
     * @param _isReturnBackPrincipal 是否返还本金给用户 true:返还OpenToken本金  false: 不返还OpenToken本金,本金另有用处
     */
    function _unstake(
        address _staker,
        uint256 _firstStakedTime,
        bool _isReturnBackPrincipal
    )
        private
        returns (
            uint256 currentRebasingAmount_,
            uint256 principal_,
            uint256 reward_
        )
    {
        //校验质押时间的有效性
        require(
            userStakeTimesByAddress[_staker].contains(_firstStakedTime),
            "invalid _firstStakedTime"
        );
        //在质押列表移除这笔记录
        userStakeTimesByAddress[_staker].remove(_firstStakedTime);
        (
            //计算rebase后的总额、本金、收益
            currentRebasingAmount_,
            principal_,
            reward_
        ) = getCurrentRebasingAmount(_staker, _firstStakedTime);

        //保存用户质押的信息
        UserStakeInfo storage stakeInfo = userStakeInfoOf[_staker][
            _firstStakedTime
        ];
        require(principal_ > 0, "staked balance not enough");
        require(
            principal_ <= principalByAddress[_staker],
            "principal not enough"
        );

        stakeInfo.principalAmount = 0; //本金归零
        stakeInfo.rebasingAmount = 0; //rebase资金总额归零

        //保存rebaseEpoch信息，所有stake的资金都默认最低收益
        RebaseEpochInfo storage rateEpochInfo = rebaseEpochInfoOf[
            stakeInfo.rebaseRateInfoId
        ];

        //总本金减少
        rateEpochInfo.principalTotal -= principal_;
        //rebase中的资金减少
        if (stakeInfo.minRebaseRateStartBlock <= epoch.latestEndBlock) {
            //一直是低收益率，或者已到期后从高收益率转移到地收益率池子的资金
            rateEpochInfo
                .defaultRateRebasingAmountTotal -= currentRebasingAmount_;
        } else {
            //当前仍是高收益率的资金
            rateEpochInfo.highRateRebasingAmountTotal -= currentRebasingAmount_;
        }

        //减少将来到期的资金
        uint256 expireBlock = stakeInfo.minRebaseRateStartBlock;
        if (stakeInfo.savedEpochBlock != expireBlock) {
            uint256 blockCount = expireBlock.sub(stakeInfo.savedEpochBlock);
            uint256 rebaseRateInfoId = stakeInfo.rebaseRateInfoId;
            principalExpireInfoOf[expireBlock][rebaseRateInfoId][blockCount]
                .expirePrincipal -= principal_;
        }

        //只要unstake，会转移所有的rebase收益到release合约
        _sendOpenTokenReward(_staker, reward_);

        uint256 takeSOpenToken = reward_;
        //openToken转给用户
        if (_isReturnBackPrincipal) {
            //返还本金
            IERC20(OpenToken).safeTransfer(_staker, principal_);
            //变更质押份额
            _changeStakeAmount(_staker, 0, principal_);
            //如果返还本金，也要扣除相应的sOpenToken
            takeSOpenToken += principal_;
        }

        //扣减sOpenToken
        if (takeSOpenToken > 0)
            IRebaseOpenToken(sOpenToken).decreaseTotalSupply(
                takeSOpenToken,
                _staker
            );
        emit Unstake(_firstStakedTime, takeSOpenToken);
    }

    /**
     * @notice  保存新的质押数据
     * @param _staker 质押者的钱包地址
     * @param _receipt 质押数据记录入该钱包地址
     * @param _rebaseRateInfoId 本记录对应收益率配置的id
     * @param _principalAmount 本次质押，登记有效的OpenToken本金金额是多少
     * @param _takeOpenTokenAmountFromStaker 本次从质押者的钱包扣除多少OpenToken  情况一：从旧版本staking迁移数据过来时，迁移的金额可能大于本金。   情况二：从低rebase收益提高到高rebase收益率时，本金大于0，但不需要从用户钱包扣OpenToken,但需要扣NectarToken  情况三：用户直接质押时，本金等扣除的OpenToken金额
     * @param _stakeBlocks 该质押数据的高收益率在多少个区块内有效
     * @param _isTakeNectarTokenFromStaker 是否需要从用户钱包扣除NectarToken, true:需要扣除   false: 不需要扣
     */
    function _stake(
        address _staker,
        address _receipt,
        uint256 _rebaseRateInfoId,
        uint256 _principalAmount,
        uint256 _takeOpenTokenAmountFromStaker,
        uint256 _stakeBlocks,
        bool _isTakeNectarTokenFromStaker
    ) private {
        //检查收益率配置的ID
        require(
            IStakingConfig(stakingConfigContract).isRebaseRateInfoIdValid(
                _rebaseRateInfoId
            ),
            "invalid rateInfoId"
        );

        //扣OpenToken
        if (_takeOpenTokenAmountFromStaker > 0) {
            IERC20(OpenToken).safeTransferFrom(
                _staker,
                address(this),
                _takeOpenTokenAmountFromStaker
            );
            if (_principalAmount > 0) {
                _changeStakeAmount(_receipt, _principalAmount, 0);
                //铸造sOpenToken(质押多少OpenToken就铸造多少sOpenToken)--由于后续需求变更为旧staking合约的收益直接释放，因此这里增加的sOpenToken等于本金
                IRebaseOpenToken(sOpenToken).increaseTotalSupply(
                    _principalAmount,
                    _receipt
                );
            }
        }

        //扣NectarToken
        if (_isTakeNectarTokenFromStaker)
            _takeNectarToken(
                _staker,
                _principalAmount,
                defaultRebaseRateInfoId(),
                _rebaseRateInfoId
            );

        //从旧版本Staking合约迁移质押数据时，迁移的openToken金额可能大于本金（迁移的openToken总额=本金+收益）
        if (_takeOpenTokenAmountFromStaker > _principalAmount) {
            uint256 oldReward = _takeOpenTokenAmountFromStaker.sub(
                _principalAmount
            );
            _sendOpenTokenReward(_receipt, oldReward);
        }
        //如果本金等0，就不往下执行了
        if (_principalAmount == 0) return;

        //保存rebaseEpoch信息
        RebaseEpochInfo storage rateEpochInfo = rebaseEpochInfoOf[
            _rebaseRateInfoId
        ];
        //设置index的默认值，注意这个值在首次赋值后，不可再人工修改，否则影响收益计算
        if (rateEpochInfo.index == 0) {
            rateEpochInfo.index = ONE_AI_TOKEN;
            rateEpochInfo.rebaseRateInfoId = _rebaseRateInfoId;
        }

        //累加总本金
        rateEpochInfo.principalTotal += _principalAmount;

        //保存数据：到哪个区块 将有多少的本金 结束高收益率
        uint256 latestEndBlock = epoch.latestEndBlock;
        uint256 expireBlock = latestEndBlock.add(_stakeBlocks);
        if (_rebaseRateInfoId == defaultRebaseRateInfoId()) {
            expireBlock = epoch.latestEndBlock;
            //累加默认低收益率rebase的总资金
            rateEpochInfo.defaultRateRebasingAmountTotal += _principalAmount;
        } else {
            //累加高收益率rebase的总资金
            rateEpochInfo.highRateRebasingAmountTotal += _principalAmount;

            //累加将来到期的资金
            PrincipalExpireInfo
                storage principalExpireInfo = principalExpireInfoOf[
                    expireBlock
                ][_rebaseRateInfoId][_stakeBlocks];
            principalExpireInfo.expirePrincipal += _principalAmount;
            principalExpireInfo.stakedIndex = rateEpochInfo.index; //同一个epoch的index都相同
        }

        //每质押一次都单独保存一条记录
        uint256 nowTime = block.timestamp;
        userStakeInfoOf[_receipt][nowTime] = UserStakeInfo({
            firstTimestamp: nowTime,
            savedTimestamp: nowTime,
            savedBlock: block.number,
            savedEpochBlock: epoch.latestEndBlock,
            minRebaseRateStartBlock: expireBlock, //高收益率到期的区块
            savedIndex: rateEpochInfo.index, //当前index
            principalAmount: _principalAmount, //本金
            rebasingAmount: _principalAmount, //rebase资金
            rebaseRateInfoId: _rebaseRateInfoId
        });

        userStakeTimesByAddress[_receipt].add(nowTime);

        emit StakeOpenToken(
            _takeOpenTokenAmountFromStaker,
            _receipt,
            _rebaseRateInfoId,
            _stakeBlocks
        );
    }

    /**
     * @notice 从配置合约查询默认最低收益率配置的ID
     */
    function defaultRebaseRateInfoId() public view returns (uint256) {
        return IStakingConfig(stakingConfigContract).defaultRebaseRateInfoId();
    }

    /**
     * @notice 提高收益率时，扣除用户的NectarToken
     * @param _staker 质押者的钱包地址
     * @param _stakeOpenTokenAmount 本次质押的OpenToken金额
     * @param _fromRateId 当前的收益率ID
     * @param _toRateId 目标的收益率ID
     */
    function _takeNectarToken(
        address _staker,
        uint256 _stakeOpenTokenAmount,
        uint256 _fromRateId,
        uint256 _toRateId
    ) private {
        require(_toRateId >= defaultRebaseRateInfoId(), "check rateId");
        if (_toRateId == defaultRebaseRateInfoId()) return;
        if (_stakeOpenTokenAmount == 0) return;
        require(_fromRateId != _toRateId, "rate config error");
        (
            uint256 idFrom,
            uint256 rebaseRateFrom,
            uint256 burnNectarTokenRateFrom
        ) = IStakingConfig(stakingConfigContract).getRebaseRateInfoById(
                _fromRateId
            );

        (
            uint256 idTo,
            uint256 rebaseRateTo,
            uint256 burnNectarTokenRateTo
        ) = IStakingConfig(stakingConfigContract).getRebaseRateInfoById(
                _toRateId
            );

        //计算nectarToken消耗比率的差
        uint256 burnRateDiff = burnNectarTokenRateTo.sub(
            burnNectarTokenRateFrom
        );
        //计算要消耗的NectarToken(nectarToken精度18，openToken精度9)
        uint256 openTokenAmount = _stakeOpenTokenAmount;
        uint256 nectarTokenAmount = openTokenAmount
            .mul(10**9)
            .mul(burnRateDiff)
            .div(1000);
        //扣NectarToken
        IERC20(nectarTokenAddress).safeTransferFrom(
            _staker,
            address(this),
            nectarTokenAmount
        );
    }

    /**
     * @notice  获取下次rebase分红的总额
     */
    function getNextDistributeTotal()
        public
        view
        returns (uint256 distribute_)
    {
        uint256 distributeTotal = 0;
        (
            uint256 rateConfigSize,
            uint256[] memory rateConfigList
        ) = IStakingConfig(stakingConfigContract).getAllRebaseRateInfoIds();

        //遍历收益率配置列表
        for (uint256 i = 0; i < rateConfigSize; i++) {
            uint256 _rateInfoId = rateConfigList[i];
            //计算rebase分红数据
            (
                uint256 newIndex_,
                uint256 newHighRebasing_,
                uint256 newDefaultRebasing_,
                uint256 distributeTotal_,
                uint256 highRateDistribute_
            ) = _calculateDistributeByRateInfoId(_rateInfoId);
            distributeTotal += distributeTotal_;
        }
        return distributeTotal;
    }

    /**
     * @notice 各个收益率对应的质押信息统计
     */
    function allRebaseEpochInfoList()
        external
        view
        returns (RebaseEpochInfo[] memory results_)
    {
        (uint256 rateConfigSize, uint256[] memory rateIdList) = IStakingConfig(
            stakingConfigContract
        ).getAllRebaseRateInfoIds();

        results_ = new RebaseEpochInfo[](rateConfigSize);
        for (uint256 i = 0; i < rateConfigSize; i++) {
            uint256 rateId = rateIdList[i];
            results_[i] = rebaseEpochInfoOf[rateId];
        }
    }

    function getStakeInfoByUserAndIndex(address _staker, uint256 _index)
        public
        view
        returns (UserStakeInfo memory stakerInfo_)
    {
        uint256 timestamp = userStakeTimesByAddress[_staker].at(_index);
        stakerInfo_ = userStakeInfoOf[_staker][timestamp];
    }

    /**
     * @notice 归还rebase欠款
     * @param _repayType 欠款归还方式 0-从国库直接铸造， 1-从owner转
     */
    function rePayRebaseRewardDebt(uint256 _repayType, uint256 _amount)
        external
        onlyOwner
    {
        require(_amount > 0, "check repay amount");
        require(_amount <= rebaseRewardDebt, "check repay amount too larg");
        if (_repayType == 0) {
            //直接从国库铸造
            ITreasury(treasury).mintRewards(address(this), _amount);
        } else if (_repayType == 1) {
            IERC20(OpenToken).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }
        rebaseRewardDebt -= _amount;
    }

    /**
     * @notice 判断是否有足够的资金来支撑下个rebase
     */
    function isReservesEnoughToNextRebase()
        public
        view
        returns (
            uint256 reserves_,
            uint256 nextDistribute_,
            bool isEnough_
        )
    {
        //查询国库剩余的无风险价值
        uint256 reserves = ITreasury(treasury).excessReserves();
        //计算下个rebase需要的资金
        uint256 nextDistributeTotal = getNextDistributeTotal();
        //判断是否足够
        bool isEnough = reserves > nextDistributeTotal;
        return (reserves, nextDistributeTotal, isEnough);
    }
}
