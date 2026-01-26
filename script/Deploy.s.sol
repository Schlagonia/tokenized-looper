// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import {Id} from "../src/interfaces/morpho/IMorpho.sol";
import {InfinifiMorphoLooper} from "../src/InfinifiMorphoLooper.sol";
import {LSTMorphoLooper} from "../src/LSTMorphoLooper.sol";
import {PTMorphoLooper} from "../src/PTMorphoLooper.sol";
import {sUSDaiPTLooper} from "../src/sUSDaiPTLooper.sol";
import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";

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
    string constant DEPLOY_CONFIG = "PT_SIUSD_MAINNET";
    /// @dev Options: INFINIFI_MAINNET, LST_MAINNET, PT_CUSD_MAINNET, PT_SIUSD_MAINNET, PT_SUSDAI_ARB, LST_KATANA, APR_ORACLE
    /// @dev =============================================================

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

    /*//////////////////////////////////////////////////////////////
                        MAINNET CONFIGURATIONS
    //////////////////////////////////////////////////////////////*/

    // Morpho Blue Mainnet
    address constant MORPHO_MAINNET = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

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
                name: "PT cUSD Morpho Looper",
                collateralToken: 0x545A490f9ab534AdF409A2E682bc4098f49952e3, // PT-cUSD
                morpho: MORPHO_MAINNET,
                marketId: 0x802ec6e878dc9fe6905b8a0a18962dcca10440a87fa2242fbf4a0461c7b0c789
            }),
            pendleMarket: 0x307c15f808914Df5a5DbE17E5608f84953fFa023,
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
                name: "PT sUSDai Morpho Looper",
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
        vm.startBroadcast();

        address deployed;

        if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("INFINIFI_MAINNET")) {
            deployed = deployInfinifi(getInfinifiMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("LST_MAINNET")) {
            deployed = deployLST(getLSTMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_CUSD_MAINNET")) {
            deployed = deployPT(getPTcUSDMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_SIUSD_MAINNET")) {
            deployed = deployPT(getPTsiUSDMainnet());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("PT_SUSDAI_ARB")) {
            deployed = deploysUSDaiPT(getPTsUSDaiArbitrum());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("LST_KATANA")) {
            deployed = deployLST(getLSTKatana());
        } else if (keccak256(bytes(DEPLOY_CONFIG)) == keccak256("APR_ORACLE")) {
            deployed = deployAprOracle();
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
            Id.wrap(cfg.marketId)
        ));
    }

    function deployLST(LSTConfig memory cfg) internal returns (address) {
        return address(new LSTMorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            cfg.router
        ));
    }

    function deployPT(PTConfig memory cfg) internal returns (address) {
        return address(new PTMorphoLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            cfg.pendleMarket,
            cfg.pendleToken
        ));
    }

    function deploysUSDaiPT(PTConfig memory cfg) internal returns (address) {
        return address(new sUSDaiPTLooper(
            cfg.base.asset,
            cfg.base.name,
            cfg.base.collateralToken,
            cfg.base.morpho,
            Id.wrap(cfg.base.marketId),
            cfg.pendleMarket,
            cfg.pendleToken
        ));
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
}
