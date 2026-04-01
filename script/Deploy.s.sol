// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import {Id} from "../src/interfaces/morpho/IMorpho.sol";
import {InfinifiMorphoLooper} from "../src/morpho/InfinifiMorphoLooper.sol";
import {MorphoLooper} from "../src/morpho/MorphoLooper.sol";
import {SyrupMorphoLooper} from "../src/morpho/SyrupMorphoLooper.sol";
import {AaveLooper} from "../src/aave/AaveLooper.sol";
import {LSTAaveLooper} from "../src/aave/LSTAaveLooper.sol";
import {SyrupUSDTAaveLooper} from "../src/aave/SyrupUSDTAaveLooper.sol";
import {sUSDeAaveLooper} from "../src/aave/sUSDeAaveLooper.sol";
import {PTExchange} from "../src/periphery/PTExchange.sol";
import {sUSDaiPTExchange} from "../src/periphery/sUSDaiPTExchange.sol";
import {SUSDSUSDTExchange} from "../src/periphery/SUSDSUSDTExchange.sol";
import {UniswapUniversalRouterExchange} from "../src/periphery/UniswapUniversalRouterExchange.sol";
import {SyrupExchange} from "../src/periphery/SyrupExchange.sol";
import {FluidExchange} from "../src/periphery/FluidExchange.sol";
import {ERC4626FluidExchange} from "../src/periphery/ERC4626FluidExchange.sol";
import {WETHWstETHExchange} from "../src/periphery/WETHWstETHExchange.sol";
import {LooperKeeper} from "../src/periphery/LooperKeeper.sol";
import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";
import {AaveStrategyAprOracle} from "../src/periphery/AaveStrategyAprOracle.sol";
import {SparkStrategyAprOracle} from "../src/periphery/SparkStrategyAprOracle.sol";

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
    string public DEPLOY_CONFIG = "PT_IUSD_MAINNET";
    /// @dev Options: INFINIFI_MAINNET, LST_MAINNET, SUSDS_USDT_MAINNET, SYRUP_USDC_MAINNET, AAVE_SYRUP_USDT_MAINNET, AAVE_SUSDE_USDC_MAINNET, AAVE_SUSDE_USDT_MAINNET, AAVE_SUSDE_USDE_MAINNET, AAVE_WSTETH_WETH_MAINNET, SPARK_WSTETH_WETH_MAINNET, AAVE_WSTETH_ETH_MAINNET, SYRUP_USDC_ARB, PT_CUSD_MAINNET, PT_IUSD_MAINNET, PT_SUSDAI_ARB, LST_KATANA, MORPHO_LBTC_WBTC_MAINNET, AAVE_LBTC_WBTC_MAINNET, APR_ORACLE, AAVE_APR_ORACLE, SPARK_APR_ORACLE, LOOPER_KEEPER
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
        address syrupRouter;
        bytes32 assetCollateralV4PoolId;
    }

    struct SyrupArbConfig {
        BaseConfig base;
        address weth;
        address fluidDex;
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

    struct AaveSyrupConfig {
        AaveConfig base;
        address syrupRouter;
        bytes32 assetCollateralV4PoolId;
    }

    struct AaveFluid4626Config {
        AaveConfig base;
        address baseToken;
        address underlyingToken;
        address assetBaseFluidDex;
        address underlyingBaseFluidDex;
        address collateralBaseFluidDex;
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
    address constant USDE_MAINNET = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE_MAINNET = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant SYRUP_USDT_MAINNET = 0x356B8d89c1e1239Cbbb9dE4815c39A1474d5BA7D;

    // Mainnet Fluid DEX pools
    address constant FLUID_USDC_USDT_MAINNET = 0x667701e51B4D1Ca244F17C78F7aB8744B4C99F9B;
    address constant FLUID_USDE_USDT_MAINNET = 0xf063BD202E45d6b2843102cb4EcE339026645D4a;
    address constant FLUID_SUSDE_USDT_MAINNET = 0x1DD125C32e4B5086c63CC13B3cA02C4A2a61Fa9b;

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
            syrupRouter: 0x134cCaaA4F1e4552eC8aEcb9E4A2360dDcF8df76,
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
                weth: WETH_MAINNET,
                uniFee: 0
            }),
            syrupRouter: 0xF007476Bb27430795138C511F18F821e8D1e5Ee2,
            assetCollateralV4PoolId: 0xd861038a98942312d1495dd1313fb66c7e7de48f549a15edf3a45decf7338e1d
        });
    }

    // ===== AAVE sUSDe/USDC MAINNET =====
    function getAaveSUSDeUSDCMainnet() internal pure returns (AaveFluid4626Config memory) {
        return AaveFluid4626Config({
            base: AaveConfig({
                asset: USDC_MAINNET,
                name: "sUSDe/USDC Aave Looper",
                collateralToken: SUSDE_MAINNET,
                addressesProvider: AAVE_MAINNET_ADDRESSES_PROVIDER,
                morpho: MORPHO_MAINNET,
                eModeCategoryId: 2,
                weth: WETH_MAINNET,
                uniFee: 0
            }),
            baseToken: USDT_MAINNET,
            underlyingToken: USDE_MAINNET,
            assetBaseFluidDex: FLUID_USDC_USDT_MAINNET,
            underlyingBaseFluidDex: FLUID_USDE_USDT_MAINNET,
            collateralBaseFluidDex: FLUID_SUSDE_USDT_MAINNET
        });
    }

    // ===== AAVE sUSDe/USDT MAINNET =====
    function getAaveSUSDeUSDTMainnet() internal pure returns (AaveFluid4626Config memory) {
        return AaveFluid4626Config({
            base: AaveConfig({
                asset: USDT_MAINNET,
                name: "sUSDe/USDT Aave Looper",
                collateralToken: SUSDE_MAINNET,
                addressesProvider: AAVE_MAINNET_ADDRESSES_PROVIDER,
                morpho: MORPHO_MAINNET,
                eModeCategoryId: 2,
                weth: WETH_MAINNET,
                uniFee: 0
            }),
            baseToken: USDT_MAINNET,
            underlyingToken: USDE_MAINNET,
            assetBaseFluidDex: address(0),
            underlyingBaseFluidDex: FLUID_USDE_USDT_MAINNET,
            collateralBaseFluidDex: FLUID_SUSDE_USDT_MAINNET
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
            weth: WETH_MAINNET,
            uniFee: 0
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
            weth: WETH_MAINNET,
            uniFee: 0
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

    // ===== PT iUSD MAINNET =====
    function getPTiUSDMainnet() internal pure returns (PTConfig memory) {
        return PTConfig({
            base: BaseConfig({
                asset: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
                name: "PT iUSD Jun 25 Morpho Looper",
                collateralToken: 0x5DbF246B37E1b9ac5D08bb38233d71322AE7D166, // PT-iUSD-25JUN2026
                morpho: MORPHO_MAINNET,
                marketId: 0xdf034d0351a4c0af947e1a37ecd5ccbce60d72eac90de6fcad48c74e2869d14c
            }),
            pendleMarket: 0x517e54f58B5c587726c577ABBcAb3E74aA51161E,
            pendleToken: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 // USDC (same as asset)
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
    address constant FLUID_DEX_SYRUP_USDC_USDC_ARBITRUM = 0xc800b0e15c40a1Ff0539218100c86F4c1BAC8D9C;

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
            weth: WETH_ARBITRUM,
            fluidDex: FLUID_DEX_SYRUP_USDC_USDC_ARBITRUM
        });
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function run() external {
        DEPLOY_CONFIG = "SPARK_APR_ORACLE";
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
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SYRUP_USDC_ARB")) {
            deployed = deploySyrupArbitrum(getSyrupUSDCArbitrum());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_CUSD_MAINNET")) {
            deployed = deployPT(getPTcUSDMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_IUSD_MAINNET")) {
            deployed = deployPT(getPTiUSDMainnet());
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
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("SPARK_APR_ORACLE")) {
            deployed = deploySparkAprOracle();
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
        return address(
            new InfinifiMorphoLooper(
                cfg.asset, cfg.name, cfg.collateralToken, cfg.morpho, Id.wrap(cfg.marketId), LOOPER_GOVERNANCE
            )
        );
    }

    function deployLST(LSTConfig memory cfg) internal returns (address) {
        UniswapUniversalRouterExchange exchange = new UniswapUniversalRouterExchange(cfg.base.asset);
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
        SyrupExchange exchange = new SyrupExchange(cfg.weth, cfg.base.asset, cfg.base.collateralToken, cfg.syrupRouter);

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
        exchange.setV4Pool(cfg.base.asset, cfg.base.collateralToken, cfg.assetCollateralV4PoolId);

        return address(looper);
    }

    function deploySyrupArbitrum(SyrupArbConfig memory cfg) internal returns (address) {
        FluidExchange exchange = new FluidExchange(cfg.weth);
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
        exchange.setBase(cfg.base.asset);
        exchange.setFluidDex(cfg.base.asset, cfg.base.collateralToken, cfg.fluidDex);

        return address(looper);
    }

    function deployPT(PTConfig memory cfg) internal returns (address) {
        PTExchange exchange =
            new PTExchange(cfg.base.asset, cfg.base.collateralToken, cfg.pendleMarket, cfg.pendleToken);

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
        sUSDaiPTExchange exchange =
            new sUSDaiPTExchange(cfg.base.asset, cfg.base.collateralToken, cfg.pendleMarket, cfg.pendleToken);

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

    function deployMorphoLBTCWBTC(BaseConfig memory cfg) internal returns (address) {
        UniswapUniversalRouterExchange exchange = new UniswapUniversalRouterExchange(WETH_MAINNET);
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

        uint24 uniFee = uint24(vm.envOr("MORPHO_LBTC_WBTC_UNI_FEE", uint256(500)));
        exchange.setUniFees(cfg.asset, cfg.collateralToken, uniFee);

        return address(looper);
    }

    function deployAave(AaveConfig memory cfg) internal returns (address) {
        UniswapUniversalRouterExchange exchange = new UniswapUniversalRouterExchange(cfg.weth);
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

        uint24 uniFee = uint24(vm.envOr("AAVE_LBTC_WBTC_UNI_FEE", uint256(cfg.uniFee)));
        exchange.setUniFees(cfg.asset, cfg.collateralToken, uniFee);

        return address(looper);
    }

    function deployAaveLST(AaveConfig memory cfg) internal returns (address) {
        WETHWstETHExchange exchange = new WETHWstETHExchange();
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
        exchange.setStrategy(address(looper));

        return address(looper);
    }

    function deployAaveSUSDe(AaveFluid4626Config memory cfg) internal returns (address) {
        ERC4626FluidExchange exchange =
            new ERC4626FluidExchange(cfg.base.weth, cfg.baseToken, cfg.base.asset, cfg.base.collateralToken);
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
        _configureERC4626FluidExchange(exchange, address(looper), cfg);

        return address(looper);
    }

    function _configureERC4626FluidExchange(
        ERC4626FluidExchange exchange,
        address strategy,
        AaveFluid4626Config memory cfg
    ) internal {
        exchange.setStrategy(strategy);
        exchange.setDeposit(true);
        if (cfg.assetBaseFluidDex != address(0) && cfg.base.asset != cfg.baseToken) {
            exchange.setFluidDex(cfg.base.asset, cfg.baseToken, cfg.assetBaseFluidDex);
        }

        if (cfg.underlyingBaseFluidDex != address(0) && cfg.underlyingToken != cfg.base.asset) {
            exchange.setFluidDex(cfg.underlyingToken, cfg.baseToken, cfg.underlyingBaseFluidDex);
        }

        exchange.setFluidDex(cfg.base.collateralToken, cfg.baseToken, cfg.collateralBaseFluidDex);
    }

    function deployAaveSyrup(AaveSyrupConfig memory cfg) internal returns (address) {
        SyrupExchange exchange =
            new SyrupExchange(cfg.base.weth, cfg.base.asset, cfg.base.collateralToken, cfg.syrupRouter);
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
        exchange.setStrategy(address(looper));
        exchange.setBase(cfg.base.asset);
        exchange.setV4Pool(cfg.base.asset, cfg.base.collateralToken, cfg.assetCollateralV4PoolId);
        exchange.setMint(vm.envOr("SYRUP_MAINNET_USE_MINT", true));

        uint24 uniFee = uint24(vm.envOr("AAVE_SYRUP_USDT_UNI_FEE", uint256(cfg.base.uniFee)));
        if (uniFee != 0) {
            exchange.setUniFees(cfg.base.asset, cfg.base.collateralToken, uniFee);
        }

        return address(looper);
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

    function deploySparkAprOracle() internal returns (address) {
        address governance = vm.envOr("SPARK_APR_ORACLE_GOV", vm.envOr("APR_ORACLE_GOV", address(0)));
        require(governance != address(0), "SPARK_APR_ORACLE_GOV");

        bytes32 salt = vm.envOr("SPARK_APR_ORACLE_SALT", vm.envOr("APR_ORACLE_SALT", bytes32(0)));
        bytes memory initCode = abi.encodePacked(type(SparkStrategyAprOracle).creationCode, abi.encode(governance));

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
