import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@typechain/hardhat";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";
import "dotenv/config";

const config: HardhatUserConfig = {
  // defaultNetwork: "polygon_amoy",

  etherscan: {
    apiKey: {
      lorenzo_testnet: "abc",
    },
    customChains: [
      {
        network: "lorenzo_testnet",
        chainId: 83291,

        urls: {
          browserURL: "https://scan-testnet.lorenzo-protocol.xyz/",
          apiURL: "https://scan-testnet.lorenzo-protocol.xyz/api/",
        },
      },
    ],
  },
  networks: {
    lorenzo_testnet: {
      url: "https://rpc-testnet.lorenzo-protocol.xyz",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
    polygon_amoy: {
      url: "https://rpc-amoy.polygon.technology",
      accounts: [
        "7c5b27c4f043051e405d03469e3f9dfe5b65df74376dcaf70db003d63a976efc",
      ],
    },
  },
  solidity: {
    compilers: [
      {
        version: "0.8.19",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
};

export default config;
