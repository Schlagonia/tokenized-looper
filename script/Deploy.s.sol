// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

import {Id} from "../src/interfaces/morpho/IMorpho.sol";
import {InfinifiMorphoLooper} from "../src/morpho/InfinifiMorphoLooper.sol";
import {MorphoLooper} from "../src/morpho/MorphoLooper.sol";
import {OriginMorphoLooper} from "../src/morpho/OriginMorphoLooper.sol";
import {sUSDeMorphoLooper} from "../src/morpho/sUSDeMorphoLooper.sol";
import {SyrupMorphoLooper} from "../src/morpho/SyrupMorphoLooper.sol";
import {AaveLooper} from "../src/aave/AaveLooper.sol";
import {LSTAaveLooper} from "../src/aave/LSTAaveLooper.sol";
import {SyrupUSDTAaveLooper} from "../src/aave/SyrupUSDTAaveLooper.sol";
import {sUSDeAaveLooper} from "../src/aave/sUSDeAaveLooper.sol";
import {MetaExchange} from "../src/periphery/MetaExchange.sol";
import {WETHWstETHExchange} from "../src/periphery/WETHWstETHExchange.sol";
import {LooperKeeper} from "../src/periphery/LooperKeeper.sol";
import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";
import {AaveStrategyAprOracle} from "../src/periphery/AaveStrategyAprOracle.sol";
import {IAaveLooper} from "../src/interfaces/IAaveLooper.sol";

interface ICreateXDeployer {
    function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
}

/// @title Deploy Script for Morpho Loopers
/// @notice Generic deployment script - change DEPLOY_CONFIG to select strategy
contract Deploy is Script {
    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @dev ========== CHANGE THIS LINE TO SELECT DEPLOYMENT ==========
    string public DEPLOY_CONFIG = "MAINNET_BATCH";
    /// @dev Options: MAINNET_BATCH, INFINIFI_MAINNET, LST_MAINNET, SUSDS_USDT_MAINNET, SUSDE_PYUSD_MAINNET, SUSDE_USDTB_MAINNET, SYRUP_USDC_MAINNET, AAVE_SYRUP_USDT_MAINNET, AAVE_SUSDE_USDC_MAINNET, AAVE_SUSDE_USDT_MAINNET, AAVE_WSTETH_WETH_MAINNET, SPARK_WSTETH_WETH_MAINNET, ORIGIN_USDC_MAINNET, SYRUP_USDC_ARB, PT_CUSD_MAINNET, PT_IUSD_MAINNET, PT_SUSDAI_ARB, MORPHO_LBTC_WBTC_MAINNET, AAVE_LBTC_WBTC_MAINNET, APR_ORACLE, AAVE_APR_ORACLE, LOOPER_KEEPER
    /// @dev =============================================================

    address internal constant DEFAULT_GOVERNANCE = 0x88Ba032be87d5EF1fbE87336B7090767F367BF73;

    /// @dev Global looper governance used by all looper deployments in this script run.
    address public LOOPER_GOVERNANCE = 0x88Ba032be87d5EF1fbE87336B7090767F367BF73;

    /// @dev Final governance for exchange deployments created by this script.
    address public EXCHANGE_GOVERNANCE = 0x1b5f15DCb82d25f91c65b53CEe151E8b9fBdD271;
    address public META_EXCHANGE = 0x3E7A91F87c1b6C9D8FA806235fd69Aa0D7577caA;

    /// @dev CreateX deployer for CREATE2 deployments
    address constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    address internal lastMetaExchange;

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
    }

    struct PTConfig {
        BaseConfig base;
    }

    struct SyrupConfig {
        BaseConfig base;
        address weth;
    }

    struct SyrupArbConfig {
        BaseConfig base;
        address weth;
    }

    struct AaveConfig {
        address asset;
        string name;
        address collateralToken;
        address addressesProvider;
        address morpho;
        uint8 eModeCategoryId;
        address weth;
    }

    struct AaveSyrupConfig {
        AaveConfig base;
    }

    struct AaveSUSDeConfig {
        AaveConfig base;
    }

    /*//////////////////////////////////////////////////////////////
                        MAINNET CONFIGURATIONS
    //////////////////////////////////////////////////////////////*/

    // Morpho Blue Mainnet
    address constant MORPHO_MAINNET = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // Mainnet core addresses
    address constant WETH_MAINNET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_MAINNET_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant SPARK_MAINNET_ADDRESSES_PROVIDER = 0x02C3eA4e34C0cBd694D2adFa2c690EECbC1793eE;

    // Mainnet BTC assets
    address constant WBTC_MAINNET = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant LBTC_MAINNET = 0x8236a87084f8B84306f72007F36F2618A5634494;

    // Mainnet ETH / stable assets
    address constant WSTETH_MAINNET = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT_MAINNET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDTB_MAINNET = 0xC139190F447e929f090Edeb554D95AbB8b18aC1C;
    address constant USDS_MAINNET = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant PYUSD_MAINNET = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant SUSDE_MAINNET = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant SYRUP_USDC_MAINNET = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    address constant SYRUP_USDT_MAINNET = 0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D;
    address constant WOUSD_MAINNET = 0xD2af830E8CBdFed6CC11Bab697bB25496ed6FA62;

    // ===== INFINIFI MAINNET (USDC/sIUSD) =====
    function getInfinifiMainnet() internal pure returns (BaseConfig memory) {
        return BaseConfig({
            asset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            name: "sIUSD/USDC Morpho Looper",
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
            })
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
            })
        });
    }

    // ===== sUSDe/PYUSD MAINNET =====
    function getSUSDePYUSDMainnet() internal pure returns (LSTConfig memory) {
        return LSTConfig({
            base: BaseConfig({
                asset: PYUSD_MAINNET,
                name: "sUSDe/PYUSD Morpho Looper",
                collateralToken: SUSDE_MAINNET,
                morpho: MORPHO_MAINNET,
                marketId: 0x90ef0c5a0dc7c4de4ad4585002d44e9d411d212d2f6258e94948beecf8b4c0d5
            })
        });
    }

    // ===== sUSDe/USDtb MAINNET =====
    function getSUSDeUSDTBMainnet() internal pure returns (LSTConfig memory) {
        return LSTConfig({
            base: BaseConfig({
                asset: USDTB_MAINNET,
                name: "sUSDe/USDtb Morpho Looper",
                collateralToken: SUSDE_MAINNET,
                morpho: MORPHO_MAINNET,
                marketId: 0x88a18b2f4d94e7ad27a381b15531c06abf05a7c99dd5d3c3679875fed6f7e742
            })
        });
    }

    // ===== syrupUSDC/PYUSD MAINNET =====
    function getSyrupUSDCMainnet() internal pure returns (SyrupConfig memory) {
        return SyrupConfig({
            base: BaseConfig({
                asset: PYUSD_MAINNET,
                name: "syrupUSDC/PYUSD Morpho Looper",
                collateralToken: SYRUP_USDC_MAINNET,
                morpho: MORPHO_MAINNET,
                marketId: 0xc9629945524f3fde56c7e8854a6c3d48e76b9d97236abbe73c750fcc7aeb8501
            }),
            weth: WETH_MAINNET
        });
    }

    // ===== wOUSD/USDC MAINNET =====
    function getOriginUSDCMainnet() internal pure returns (BaseConfig memory) {
        return BaseConfig({
            asset: USDC_MAINNET,
            name: "wOUSD/USDC Morpho Looper",
            collateralToken: WOUSD_MAINNET,
            morpho: MORPHO_MAINNET,
            marketId: 0xad656d430bb3d8c1469bf45c8ad4ebae1b04be04757c69fa424eec78d7b3f4dc
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
            weth: WETH_MAINNET
        });
    }

    // ===== AAVE syrupUSDT/USDT MAINNET =====
    function getAaveSyrupUSDTMainnet() internal pure returns (AaveSyrupConfig memory) {
        return AaveSyrupConfig({
            base: AaveConfig({
                asset: 0xdAC17F958D2ee523a2206206994597C13D831ec7, // USDT
                name: "syrupUSDT Aave Looper",
                collateralToken: SYRUP_USDT_MAINNET, // syrupUSDT
                addressesProvider: AAVE_MAINNET_ADDRESSES_PROVIDER,
                morpho: MORPHO_MAINNET,
                eModeCategoryId: 0,
                weth: WETH_MAINNET
            })
        });
    }

    // ===== AAVE sUSDe/USDC MAINNET =====
    function getAaveSUSDeUSDCMainnet() internal pure returns (AaveSUSDeConfig memory) {
        return AaveSUSDeConfig({
            base: AaveConfig({
                asset: USDC_MAINNET,
                name: "sUSDe/USDC Aave Looper",
                collateralToken: SUSDE_MAINNET,
                addressesProvider: AAVE_MAINNET_ADDRESSES_PROVIDER,
                morpho: MORPHO_MAINNET,
                eModeCategoryId: 2,
                weth: WETH_MAINNET
            })
        });
    }

    // ===== AAVE sUSDe/USDT MAINNET =====
    function getAaveSUSDeUSDTMainnet() internal pure returns (AaveSUSDeConfig memory) {
        return AaveSUSDeConfig({
            base: AaveConfig({
                asset: USDT_MAINNET,
                name: "sUSDe/USDT Aave Looper",
                collateralToken: SUSDE_MAINNET,
                addressesProvider: AAVE_MAINNET_ADDRESSES_PROVIDER,
                morpho: MORPHO_MAINNET,
                eModeCategoryId: 2,
                weth: WETH_MAINNET
            })
        });
    }

    // ===== AAVE wstETH/WETH MAINNET =====
    function getAaveWstETHWETHMainnet() internal pure returns (AaveConfig memory) {
        return AaveConfig({
            asset: WETH_MAINNET,
            name: "wstETH/WETH Aave Looper",
            collateralToken: WSTETH_MAINNET,
            addressesProvider: AAVE_MAINNET_ADDRESSES_PROVIDER,
            morpho: MORPHO_MAINNET,
            eModeCategoryId: 1,
            weth: WETH_MAINNET
        });
    }

    // ===== SPARK wstETH/WETH MAINNET =====
    function getSparkWstETHWETHMainnet() internal pure returns (AaveConfig memory) {
        return AaveConfig({
            asset: WETH_MAINNET,
            name: "wstETH/WETH Spark Looper",
            collateralToken: WSTETH_MAINNET,
            addressesProvider: SPARK_MAINNET_ADDRESSES_PROVIDER,
            morpho: MORPHO_MAINNET,
            eModeCategoryId: 1,
            weth: WETH_MAINNET
        });
    }

    // ===== MORPHO LBTC/WBTC MAINNET =====
    function getMorphoLBTCWBTCMainnet() internal pure returns (BaseConfig memory) {
        return BaseConfig({
            asset: WBTC_MAINNET,
            name: "LBTC/WBTC Morpho Looper",
            collateralToken: LBTC_MAINNET,
            morpho: MORPHO_MAINNET,
            marketId: 0xf6a056627a51e511ec7f48332421432ea6971fc148d8f3c451e14ea108026549
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
            })
        });
    }

    // ===== PT iUSD MAINNET =====
    function getPTiUSDMainnet() internal pure returns (PTConfig memory) {
        return PTConfig({
            base: BaseConfig({
                asset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
                name: "PT iUSD Jun 25 Morpho Looper",
                collateralToken: 0x5DbF246B37E1b9ac5D08bb38233d71322AE7D166, // PT-iUSD-25JUN2026
                morpho: MORPHO_MAINNET,
                marketId: 0xdf034d0351a4c0af947e1a37ecd5ccbce60d72eac90de6fcad48c74e2869d14c
            })
        });
    }

    /*//////////////////////////////////////////////////////////////
                        ARBITRUM CONFIGURATIONS
    //////////////////////////////////////////////////////////////*/

    // Morpho Blue Arbitrum
    address constant MORPHO_ARBITRUM = 0x6c247b1F6182318877311737BaC0844bAa518F5e;

    // Arbitrum core addresses
    address constant WETH_ARBITRUM = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant SYRUP_USDC_ARBITRUM = 0x41CA7586cC1311807B4605fBB748a3B8862b42b5;

    // ===== PT sUSDai ARBITRUM =====
    function getPTsUSDaiArbitrum() internal pure returns (PTConfig memory) {
        return PTConfig({
            base: BaseConfig({
                asset: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC (Arbitrum)
                name: "PT sUSDai Feb 18 Morpho Looper",
                collateralToken: 0x1BF1311FCF914A69Dd5805C9B06b72F80539cB3f, // PT-sUSDai
                morpho: MORPHO_ARBITRUM,
                marketId: 0x7717f1e04510390518811b3133ea47c298094ddd1d806ed8f8867d88c727bad7
            })
        });
    }

    // ===== syrupUSDC/USDC ARBITRUM =====
    function getSyrupUSDCArbitrum() internal pure returns (SyrupArbConfig memory) {
        return SyrupArbConfig({
            base: BaseConfig({
                asset: USDC_ARBITRUM,
                name: "syrupUSDC/USDC Morpho Looper",
                collateralToken: SYRUP_USDC_ARBITRUM,
                morpho: MORPHO_ARBITRUM,
                marketId: 0xf86f3edd6f16cd8211f4d206866dc4ecd41be6211063ac11f8508e1b7112ef40
            }),
            weth: WETH_ARBITRUM
        });
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function run() external {
        DEPLOY_CONFIG = vm.envOr("DEPLOY_CONFIG", DEPLOY_CONFIG);
        LOOPER_GOVERNANCE = vm.envOr("LOOPER_GOVERNANCE", LOOPER_GOVERNANCE);
        EXCHANGE_GOVERNANCE = vm.envOr("EXCHANGE_GOVERNANCE", EXCHANGE_GOVERNANCE);
        META_EXCHANGE = vm.envOr("META_EXCHANGE", META_EXCHANGE);
        deploy();
    }

    function deploy() internal {
        lastMetaExchange = address(0);
        vm.startBroadcast();

        address deployed;

        if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("MAINNET_BATCH")) {
            deployed = deployMainnetBatch();
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("INFINIFI_MAINNET")) {
            deployed = deployInfinifi(getInfinifiMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SUSDS_USDT_MAINNET")) {
            deployed = deploySUSDSUSDT(getSUSDSUSDTMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SUSDE_PYUSD_MAINNET")) {
            deployed = deploySUSDe(getSUSDePYUSDMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SUSDE_USDTB_MAINNET")) {
            deployed = deploySUSDe(getSUSDeUSDTBMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SYRUP_USDC_MAINNET")) {
            deployed = deploySyrup(getSyrupUSDCMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("AAVE_SYRUP_USDT_MAINNET")) {
            deployed = deployAaveSyrup(getAaveSyrupUSDTMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("AAVE_SUSDE_USDC_MAINNET")) {
            deployed = deployAaveSUSDe(getAaveSUSDeUSDCMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("AAVE_SUSDE_USDT_MAINNET")) {
            deployed = deployAaveSUSDe(getAaveSUSDeUSDTMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("AAVE_WSTETH_WETH_MAINNET")) {
            deployed = deployAaveLST(getAaveWstETHWETHMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SPARK_WSTETH_WETH_MAINNET")) {
            deployed = deployAaveLST(getSparkWstETHWETHMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("ORIGIN_USDC_MAINNET")) {
            deployed = deployOrigin(getOriginUSDCMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SYRUP_USDC_ARB")) {
            deployed = deploySyrupArbitrum(getSyrupUSDCArbitrum());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_CUSD_MAINNET")) {
            deployed = deployPT(getPTcUSDMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_IUSD_MAINNET")) {
            deployed = deployPT(getPTiUSDMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_SUSDAI_ARB")) {
            deployed = deploysUSDaiPT(getPTsUSDaiArbitrum());
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
        console.log("LooperGovernance:", LOOPER_GOVERNANCE);
        if (lastMetaExchange != address(0)) {
            console.log("MetaExchange:", lastMetaExchange);
        }
    }

    function deployMainnetBatch() internal returns (address) {
        address sms = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;
        address syrup = deploySyrup(getSyrupUSDCMainnet());
        console.log("syrupUSDC/PYUSD Morpho:", syrup);

        IAaveLooper(syrup).setPendingManagement(sms);

        address siusd = deployInfinifi(getInfinifiMainnet());
        console.log("sIUSD/USDC Morpho:", siusd);

        IAaveLooper(siusd).setPendingManagement(sms);

        address spark = deployAaveLST(getSparkWstETHWETHMainnet());
        console.log("wstETH/WETH Spark:", spark);

        IAaveLooper(spark).setPendingManagement(sms);

        address origin = deployOrigin(getOriginUSDCMainnet());
        console.log("wOUSD/USDC Morpho:", origin);

        IAaveLooper(origin).setPendingManagement(sms);

        address susde = deploySUSDe(getSUSDeUSDTBMainnet());
        console.log("sUSDe/USDT Morpho:", susde);

        IAaveLooper(susde).setPendingManagement(sms);

        return origin;
    }

    function deployInfinifi(BaseConfig memory cfg) internal returns (address) {
        return address(
            new InfinifiMorphoLooper(
                cfg.asset, cfg.name, cfg.collateralToken, cfg.morpho, Id.wrap(cfg.marketId), LOOPER_GOVERNANCE
            )
        );
    }

    function deploySUSDSUSDT(LSTConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();

        MorphoLooper looper = new MorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );

        return address(looper);
    }

    function deploySUSDe(LSTConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();

        sUSDeMorphoLooper looper = new sUSDeMorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );

        return address(looper);
    }

    function deploySyrup(SyrupConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();

        SyrupMorphoLooper looper = new SyrupMorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );

        return address(looper);
    }

    function deployOrigin(BaseConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();

        OriginMorphoLooper looper = new OriginMorphoLooper(
            cfg.asset,
            cfg.name,
            cfg.collateralToken,
            cfg.morpho,
            Id.wrap(cfg.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );

        return address(looper);
    }

    function deploySyrupArbitrum(SyrupArbConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();

        MorphoLooper looper = new MorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );

        return address(looper);
    }

    function deployPT(PTConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();

        MorphoLooper looper = new MorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );

        return address(looper);
    }

    function deploysUSDaiPT(PTConfig memory cfg) internal returns (address) {
        return deployPT(cfg);
    }

    function deployMorphoLBTCWBTC(BaseConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();
        MorphoLooper looper = new MorphoLooper(
            cfg.asset,
            cfg.name,
            cfg.collateralToken,
            cfg.morpho,
            Id.wrap(cfg.marketId),
            address(exchange),
            LOOPER_GOVERNANCE
        );

        return address(looper);
    }

    function deployAave(AaveConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();
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

        return address(looper);
    }

    function deployAaveLST(AaveConfig memory cfg) internal returns (address) {
        WETHWstETHExchange exchange = new WETHWstETHExchange(0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7);
        LSTAaveLooper looper = new LSTAaveLooper(
            cfg.asset,
            cfg.name,
            cfg.collateralToken,
            cfg.addressesProvider,
            cfg.morpho,
            cfg.eModeCategoryId,
            address(exchange),
            LOOPER_GOVERNANCE
        );
        return address(looper);
    }

    function deployAaveSUSDe(AaveSUSDeConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();
        sUSDeAaveLooper looper = new sUSDeAaveLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.addressesProvider,
            cfg.base.morpho,
            cfg.base.eModeCategoryId,
            address(exchange),
            LOOPER_GOVERNANCE
        );

        return address(looper);
    }

    function deployAaveSyrup(AaveSyrupConfig memory cfg) internal returns (address) {
        MetaExchange exchange = _resolveMetaExchange();
        SyrupUSDTAaveLooper looper = new SyrupUSDTAaveLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.addressesProvider,
            cfg.base.morpho,
            cfg.base.eModeCategoryId,
            address(exchange),
            LOOPER_GOVERNANCE
        );

        return address(looper);
    }

    function _resolveMetaExchange() internal returns (MetaExchange exchange) {
        require(META_EXCHANGE != address(0), "META_EXCHANGE");
        exchange = MetaExchange(payable(META_EXCHANGE));
        lastMetaExchange = address(exchange);
        return exchange;
    }

    function deployAprOracle() internal returns (address) {
        address governance = vm.envOr("APR_ORACLE_GOV", address(0));
        require(governance != address(0), "APR_ORACLE_GOV");

        bytes32 salt = vm.envOr("APR_ORACLE_SALT", bytes32(0));
        bytes memory initCode = abi.encodePacked(type(StrategyAprOracle).creationCode, abi.encode(governance));

        return ICreateXDeployer(CREATE_X).deployCreate2(salt, initCode);
    }

    function deployAaveAprOracle() internal returns (address) {
        address governance = vm.envOr("AAVE_APR_ORACLE_GOV", vm.envOr("APR_ORACLE_GOV", address(0)));
        require(governance != address(0), "AAVE_APR_ORACLE_GOV");

        bytes32 salt = vm.envOr("AAVE_APR_ORACLE_SALT", vm.envOr("APR_ORACLE_SALT", bytes32(0)));
        bytes memory initCode = abi.encodePacked(type(AaveStrategyAprOracle).creationCode, abi.encode(governance));

        return ICreateXDeployer(CREATE_X).deployCreate2(salt, initCode);
    }

    function deployLooperKeeper() internal returns (address) {
        address publicAllocator = vm.envOr("EXECUTOR_PUBLIC_ALLOCATOR", address(0));
        address governance = vm.envOr("EXECUTOR_GOVERNANCE", address(0));
        require(publicAllocator != address(0), "EXECUTOR_PUBLIC_ALLOCATOR");
        require(governance != address(0), "EXECUTOR_GOVERNANCE");

        return address(new LooperKeeper(governance, publicAllocator));
    }
}
