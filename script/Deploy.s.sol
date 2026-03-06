// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import {Id} from "../src/interfaces/morpho/IMorpho.sol";
import {InfinifiMorphoLooper} from "../src/morpho/InfinifiMorphoLooper.sol";
import {MorphoLooper} from "../src/morpho/MorphoLooper.sol";
import {SyrupMorphoLooper} from "../src/morpho/SyrupMorphoLooper.sol";
import {AaveLooper} from "../src/aave/AaveLooper.sol";
import {PTExchange} from "../src/periphery/PTExchange.sol";
import {sUSDaiPTExchange} from "../src/periphery/sUSDaiPTExchange.sol";
import {SUSDSUSDTExchange} from "../src/periphery/SUSDSUSDTExchange.sol";
import {UniswapUniversalRouterExchange} from "../src/periphery/UniswapUniversalRouterExchange.sol";
import {LooperKeeper} from "../src/periphery/LooperKeeper.sol";
import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";
import {AaveStrategyAprOracle} from "../src/periphery/AaveStrategyAprOracle.sol";

interface ICreateXDeployer {
    function deployCreate2(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address newContract);
}

/// @title Deploy Script for Morpho Loopers
/// @notice Generic deployment script - change DEPLOY_CONFIG to select strategy
contract Deploy is Script {
    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @dev ========== CHANGE THIS LINE TO SELECT DEPLOYMENT ==========
    string public DEPLOY_CONFIG = "PT_SIUSD_MAINNET";
    /// @dev Options: INFINIFI_MAINNET, LST_MAINNET, SUSDS_USDT_MAINNET, SYRUP_USDC_MAINNET, PT_CUSD_MAINNET, PT_SIUSD_MAINNET, PT_SUSDAI_ARB, LST_KATANA, MORPHO_LBTC_WBTC_MAINNET, AAVE_LBTC_WBTC_MAINNET, APR_ORACLE, AAVE_APR_ORACLE, LOOPER_KEEPER
    /// @dev =============================================================

    /// @dev Global looper governance used by all looper deployments in this script run.
    address public LOOPER_GOVERNANCE = 0x88Ba032be87d5EF1fbE87336B7090767F367BF73;

    /// @dev CreateX deployer for CREATE2 deployments
    address constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /*//////////////////////////////////////////////////////////////
                            CONFIG STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct BaseConfig {
        address asset;
        string name;
        address collateralToken;
        address morpho;
        bytes32 marketId;
    }

    struct LSTConfig {
        BaseConfig base;
        address router;
    }

    struct PTConfig {
        BaseConfig base;
        address pendleMarket;
        address pendleToken;
    }

    struct SyrupConfig {
        BaseConfig base;
        address weth;
        bytes32 assetCollateralV4PoolId;
    }

    struct AaveConfig {
        address asset;
        string name;
        address collateralToken;
        address addressesProvider;
        address morpho;
        uint8 eModeCategoryId;
        address weth;
        uint24 uniFee;
    }

    /*//////////////////////////////////////////////////////////////
                        MAINNET CONFIGURATIONS
    //////////////////////////////////////////////////////////////*/

    // Morpho Blue Mainnet
    address constant MORPHO_MAINNET = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // Mainnet core addresses
    address constant WETH_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_MAINNET_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // Mainnet BTC assets
    address constant WBTC_MAINNET = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant LBTC_MAINNET = 0x8236a87084f8B84306f72007F36F2618A5634494;

    // Morpho Katana Mainnet
    address constant MORPHO_KATANA = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc;

    // ===== INFINIFI MAINNET (USDC/sIUSD) =====
    function getInfinifiMainnet() internal pure returns (BaseConfig memory) {
        return BaseConfig({
                asset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
                name: "Infinifi sIUSD Morpho Looper",
                collateralToken: 0xDBDC1Ef57537E34680B898E1FEBD3D68c7389bCB, // sIUSD
                morpho: MORPHO_MAINNET,
                marketId: 0xbbf7ce1b40d32d3e3048f5cf27eeaa6de8cb27b80194690aab191a63381d8c99
        });
    }

    // ===== LST KATANA (WETH/wstETH) =====
    function getLSTMainnet() internal pure returns (LSTConfig memory) {
        return LSTConfig({
            base: BaseConfig({
                asset: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
                name: "wstETH/WETH Morpho Looper",
                collateralToken: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, // wstETH
                morpho: MORPHO_MAINNET,
                marketId: 0xb8fc70e82bc5bb53e773626fcc6a23f7eefa036918d7ef216ecfb1950a94a85e
            }),
            router: 0xE592427A0AEce92De3Edee1F18E0157C05861564
        });
    }

    // ===== sUSDS/USDT MAINNET =====
    function getSUSDSUSDTMainnet() internal pure returns (LSTConfig memory) {
        return LSTConfig({
            base: BaseConfig({
                asset: 0xdAC17F958D2ee523a2206206994597C13D831ec7, // USDT
                name: "sUSDS/USDT Morpho Looper",
                collateralToken: 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD, // sUSDS
                morpho: MORPHO_MAINNET,
                marketId: 0x3274643db77a064abd3bc851de77556a4ad2e2f502f4f0c80845fa8f909ecf0b
            }),
            router: 0xE592427A0AEce92De3Edee1F18E0157C05861564
        });
    }

    // ===== syrupUSDC/USDC MAINNET =====
    function getSyrupUSDCMainnet() internal pure returns (SyrupConfig memory) {
        return SyrupConfig({
            base: BaseConfig({
                asset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
                name: "syrupUSDC/USDC Morpho Looper",
                collateralToken: 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b, // syrupUSDC
                morpho: MORPHO_MAINNET,
                marketId: 0x729badf297ee9f2f6b3f717b96fd355fc6ec00422284ce1968e76647b258cf44
            }),
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
            assetCollateralV4PoolId: 0xcdb422a853a4fa2deb364317db92ad76d1cb7a8e1b82a32219bcb41720a90228
        });
    }

    // ===== AAVE LBTC/WBTC MAINNET =====
    function getAaveLBTCWBTCMainnet() internal pure returns (AaveConfig memory) {
        return AaveConfig({
            asset: WBTC_MAINNET,
            name: "lBTC/WBTC Aave Looper",
            collateralToken: LBTC_MAINNET,
            addressesProvider: AAVE_MAINNET_ADDRESSES_PROVIDER,
            morpho: MORPHO_MAINNET,
            eModeCategoryId: 4, // LBTC_WBTC
            weth: WETH_MAINNET,
            uniFee: 500
        });
    }

    // ===== MORPHO LBTC/WBTC MAINNET =====
    function getMorphoLBTCWBTCMainnet()
        internal
        pure
        returns (BaseConfig memory)
    {
        return BaseConfig({
            asset: WBTC_MAINNET,
            name: "lBTC/WBTC Morpho Looper",
            collateralToken: LBTC_MAINNET,
            morpho: MORPHO_MAINNET,
            marketId: 0xf6a056627a51e511ec7f48332421432ea6971fc148d8f3c451e14ea108026549
        });
    }

    function getLSTKatana() internal pure returns (LSTConfig memory) {
        return LSTConfig({
            base: BaseConfig({
                asset: 0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62, // WETH
                name: "wstETH/WETH Katana Morpho Looper",
                collateralToken: 0x7Fb4D0f51544F24F385a421Db6e7D4fC71Ad8e5C, // wstETH
                morpho: MORPHO_KATANA,
                marketId: 0x22f9f76056c10ee3496dea6fefeaf2f98198ef597eda6f480c148c6d3aaa70db
            }),
            router: 0x4e1d81A3E627b9294532e990109e4c21d217376C
        });
    }

    // ===== PT cUSD MAINNET =====
    function getPTcUSDMainnet() internal pure returns (PTConfig memory) {
        return PTConfig({
            base: BaseConfig({
                asset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
                name: "PT stcUSD Jul 23 Morpho Looper",
                collateralToken: 0x2d3C279E5FcDF5b793c0a75ed90738D7369B0b83, // PT-cUSD
                morpho: MORPHO_MAINNET,
                marketId: 0x2fb3713487c7812e7309935b034f40228841666f6b048faf31fd2110ae674f20
            }),
            pendleMarket: 0xaC24A6f0068d9701EAEa76AB0B418021017F8D59,
            pendleToken: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 // USDC (same as asset)
        });
    }

    // ===== PT siUSD MAINNET =====
    function getPTsiUSDMainnet() internal pure returns (PTConfig memory) {
        return PTConfig({
            base: BaseConfig({
                asset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
                name: "PT siUSD March 25 Morpho Looper",
                collateralToken: 0xaF76B3AF3477E4a2cD0B7F80c3152108c19a25e5, // PT-siUSD
                morpho: MORPHO_MAINNET,
                marketId: 0xaac3ffcdf8a75919657e789fa72ab742a7bbfdf5bb0b87e4bbeb3c29bbbbb05c
            }),
            pendleMarket: 0x564f279B0226f60a40f1E4b8C596Feb87c383BFA,
            pendleToken: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 // USDC (same as asset)
        });
    }

    /*//////////////////////////////////////////////////////////////
                        ARBITRUM CONFIGURATIONS
    //////////////////////////////////////////////////////////////*/

    // Morpho Blue Arbitrum
    address constant MORPHO_ARBITRUM = 0x6c247b1F6182318877311737BaC0844bAa518F5e;

    // ===== PT sUSDai ARBITRUM =====
    function getPTsUSDaiArbitrum() internal pure returns (PTConfig memory) {
        return PTConfig({
            base: BaseConfig({
                asset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC (Arbitrum)
                name: "PT sUSDai Feb 18 Morpho Looper",
                collateralToken: 0x1BF1311FCF914A69Dd5805C9B06b72F80539cB3f, // PT-sUSDai
                morpho: MORPHO_ARBITRUM,
                marketId: 0x7717f1e04510390518811b3133ea47c298094ddd1d806ed8f8867d88c727bad7
            }),
            pendleMarket: 0x2092Fa5d02276B3136A50F3C2C3a6Ed45413183E,
            pendleToken: 0x0B2b2B2076d95dda7817e785989fE353fe955ef9 // sUSDai
        });
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function run() external {
        DEPLOY_CONFIG = "AAVE_LBTC_WBTC_MAINNET";
        deploy();
        return;
        if (block.chainid == 1) {
            DEPLOY_CONFIG = "PT_SIUSD_MAINNET";
            deploy();
            DEPLOY_CONFIG = "INFINIFI_MAINNET";
            deploy();
            DEPLOY_CONFIG = "LST_MAINNET";
            deploy();
            DEPLOY_CONFIG = "SUSDS_USDT_MAINNET";
            deploy();
            DEPLOY_CONFIG = "PT_CUSD_MAINNET";
            deploy();
            DEPLOY_CONFIG = "MORPHO_LBTC_WBTC_MAINNET";
            deploy();
            DEPLOY_CONFIG = "AAVE_LBTC_WBTC_MAINNET";
            deploy();
        }
        if (block.chainid == 42161) {
            DEPLOY_CONFIG = "PT_SUSDAI_ARB";
            deploy();
        }
        if (block.chainid == 747474) {
            DEPLOY_CONFIG = "LST_KATANA";
            deploy();
        }

        DEPLOY_CONFIG = "APR_ORACLE";
        deploy();
        DEPLOY_CONFIG = "AAVE_APR_ORACLE";
        deploy();
        DEPLOY_CONFIG = "LOOPER_KEEPER";
        deploy();
    }

    function deploy() internal {
        vm.startBroadcast();

        address deployed;

        if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("INFINIFI_MAINNET")) {
            deployed = deployInfinifi(getInfinifiMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("LST_MAINNET")) {
            deployed = deployLST(getLSTMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SUSDS_USDT_MAINNET")) {
            deployed = deploySUSDSUSDT(getSUSDSUSDTMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SYRUP_USDC_MAINNET")) {
            deployed = deploySyrup(getSyrupUSDCMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_CUSD_MAINNET")) {
            deployed = deployPT(getPTcUSDMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_SIUSD_MAINNET")) {
            deployed = deployPT(getPTsiUSDMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_SUSDAI_ARB")) {
            deployed = deploysUSDaiPT(getPTsUSDaiArbitrum());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("LST_KATANA")) {
            deployed = deployLST(getLSTKatana());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("MORPHO_LBTC_WBTC_MAINNET")) {
            deployed = deployMorphoLBTCWBTC(getMorphoLBTCWBTCMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("AAVE_LBTC_WBTC_MAINNET")) {
            deployed = deployAave(getAaveLBTCWBTCMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("APR_ORACLE")) {
            deployed = deployAprOracle();
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("AAVE_APR_ORACLE")) {
            deployed = deployAaveAprOracle();
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("LOOPER_KEEPER")) {
            deployed = deployLooperKeeper();
        } else {
            revert("Unknown config");
        }

        vm.stopBroadcast();

        console.log("Deployed:", deployed);
        console.log("Config:", DEPLOY_CONFIG);
    }


    function deployInfinifi(BaseConfig memory cfg) internal returns (address) {
        return address(new InfinifiMorphoLooper(
            cfg.asset,
            cfg.name,
            cfg.collateralToken,
            cfg.morpho,
            Id.wrap(cfg.marketId),
            LOOPER_GOVERNANCE
        ));
    }

    function deployLST(LSTConfig memory cfg) internal returns (address) {
        UniswapUniversalRouterExchange exchange = new UniswapUniversalRouterExchange(
                cfg.base.asset
            );
        MorphoLooper looper = new MorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );
        exchange.setStrategy(address(looper));
        exchange.setUniFees(cfg.base.asset, cfg.base.collateralToken, 100);

        return address(looper);
    }

    function deploySUSDSUSDT(LSTConfig memory cfg) internal returns (address) {
        SUSDSUSDTExchange exchange = new SUSDSUSDTExchange();
        MorphoLooper looper = new MorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );
        exchange.setStrategy(address(looper));

        return address(looper);
    }

    function deploySyrup(SyrupConfig memory cfg) internal returns (address) {
        UniswapUniversalRouterExchange exchange = new UniswapUniversalRouterExchange(
                cfg.weth
            );
        SyrupMorphoLooper looper = new SyrupMorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );
        exchange.setStrategy(address(looper));
        exchange.setBase(cfg.base.asset);
        exchange.setV4Pool(
            cfg.base.asset,
            cfg.base.collateralToken,
            cfg.assetCollateralV4PoolId
        );

        return address(looper);
    }

    function deployPT(PTConfig memory cfg) internal returns (address) {
        PTExchange exchange = new PTExchange(
            cfg.base.asset,
            cfg.base.collateralToken,
            cfg.pendleMarket,
            cfg.pendleToken
        );

        MorphoLooper looper = new MorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );
        exchange.setStrategy(address(looper));
        return address(looper);
    }

    function deploysUSDaiPT(PTConfig memory cfg) internal returns (address) {
        sUSDaiPTExchange exchange = new sUSDaiPTExchange(
            cfg.base.asset,
            cfg.base.collateralToken,
            cfg.pendleMarket,
            cfg.pendleToken
        );

        MorphoLooper looper = new MorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );
        exchange.setStrategy(address(looper));
        return address(looper);
    }

    function deployMorphoLBTCWBTC(
        BaseConfig memory cfg
    ) internal returns (address) {
        UniswapUniversalRouterExchange exchange = new UniswapUniversalRouterExchange(
                WETH_MAINNET
            );
        MorphoLooper looper = new MorphoLooper(
            cfg.asset,
            cfg.name,
            cfg.collateralToken,
            cfg.morpho,
            Id.wrap(cfg.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );
        exchange.setStrategy(address(looper));

        uint24 uniFee = uint24(
            vm.envOr("MORPHO_LBTC_WBTC_UNI_FEE", uint256(500))
        );
        exchange.setUniFees(cfg.asset, cfg.collateralToken, uniFee);

        return address(looper);
    }

    function deployAave(AaveConfig memory cfg) internal returns (address) {
        UniswapUniversalRouterExchange exchange = new UniswapUniversalRouterExchange(
                cfg.weth
            );
        AaveLooper looper = new AaveLooper(
            cfg.asset,
            cfg.name,
            cfg.collateralToken,
            cfg.addressesProvider,
            cfg.morpho,
            cfg.eModeCategoryId,
            address(exchange),
            LOOPER_GOVERNANCE
        );
        exchange.setStrategy(address(looper));

        uint24 uniFee = uint24(
            vm.envOr("AAVE_LBTC_WBTC_UNI_FEE", uint256(cfg.uniFee))
        );
        exchange.setUniFees(cfg.asset, cfg.collateralToken, uniFee);

        return address(looper);
    }

    function deployAprOracle() internal returns (address) {
        address governance = vm.envOr("APR_ORACLE_GOV", address(0));
        require(governance != address(0), "APR_ORACLE_GOV");

        bytes32 salt = vm.envOr("APR_ORACLE_SALT", bytes32(0));
        bytes memory initCode = abi.encodePacked(
            type(StrategyAprOracle).creationCode,
            abi.encode(governance)
        );

        return ICreateXDeployer(CREATE_X).deployCreate2(salt, initCode);
    }

    function deployAaveAprOracle() internal returns (address) {
        address governance = vm.envOr(
            "AAVE_APR_ORACLE_GOV",
            vm.envOr("APR_ORACLE_GOV", address(0))
        );
        require(governance != address(0), "AAVE_APR_ORACLE_GOV");

        bytes32 salt = vm.envOr(
            "AAVE_APR_ORACLE_SALT",
            vm.envOr("APR_ORACLE_SALT", bytes32(0))
        );
        bytes memory initCode = abi.encodePacked(
            type(AaveStrategyAprOracle).creationCode,
            abi.encode(governance)
        );

        return ICreateXDeployer(CREATE_X).deployCreate2(salt, initCode);
    }

    function deployLooperKeeper() internal returns (address) {
        address publicAllocator = vm.envOr(
            "EXECUTOR_PUBLIC_ALLOCATOR",
            address(0)
        );
        address governance = vm.envOr(
            "EXECUTOR_GOVERNANCE",
            address(0)
        );
        require(publicAllocator != address(0), "EXECUTOR_PUBLIC_ALLOCATOR");
        require(governance != address(0), "EXECUTOR_GOVERNANCE");

        return address(new LooperKeeper(
            governance,
            publicAllocator
        ));
    }
}
