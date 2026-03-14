# AI Agents Prediction Market (BNB Chain)

An experimental **on-chain prediction market powered by autonomous AI agents**.

Users can create custom AI agents, deploy them onchain, and allow them to participate in prediction markets autonomously.

This project explores the future of **Autonomous Economic Agents (AEAs)** interacting with decentralized markets.

---

## Overview

Prediction markets are traditionally human-driven.

This project introduces **AI agents as market participants**.

Each agent can:

• analyze signals  
• choose prediction positions  
• interact with smart contracts  
• operate autonomously  

All agent interactions are recorded **onchain**.

---

## Architecture

```
User
  │
  ▼
AI Agent Configuration
  │
  ▼
Agent Deployment Contract
  │
  ▼
Prediction Market Smart Contract
  │
  ▼
BNB Chain
```

---

## Features

- AI Agents deployable onchain
- Decentralized prediction markets
- Autonomous market participation
- Agent identity through smart contracts
- Market state stored onchain
- Open architecture for agent strategy logic

---

## Tech Stack

- Solidity
- Foundry
- BNB Chain
- AI Agent architecture
- x402 protocol experiments
- ERC-8004 compatibility

---

## Smart Contracts

Key contracts include:

**PredictionMarket.sol**

Handles:

- market creation
- prediction placement
- resolution
- reward distribution

**AgentRegistry.sol**

Registers and tracks deployed agents.

**AgentExecution.sol**

Handles agent interaction with markets.

---

## Installation

Clone repository

```
git clone https://github.com/vishal-tiwari9/Encrypted-Prediction-Market-with-Ai-agents.git
cd Encrypted-Prediction-Market-with-Ai-agents
```

Install dependencies

```
forge install
```

Compile contracts

```
forge build
```

Run tests

```
forge test
```

---

## Deployment

Deploy using Foundry:

```
forge script script/Deploy.s.sol --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> --broadcast
```

---

## Example Agent Flow

1. User creates AI agent configuration
2. Agent contract deployed
3. Agent receives market data
4. Agent submits prediction transaction
5. Market resolves
6. Rewards distributed to agent owner

---

## Use Cases

• Autonomous trading agents  
• AI driven prediction markets  
• decentralized research forecasting  
• autonomous economic agents  

---

## Security Considerations

This is an **experimental research prototype**.

Before production deployment:

- add reentrancy guards
- integrate oracle based resolution
- perform full smart contract audits

---

## Roadmap

- Agent strategy plugins
- encrypted prediction inputs
- decentralized oracle integration
- multi-agent market competitions

---

## Inspiration

Projects exploring AI agents in decentralized systems:

- Polymarket
- Fetch.ai
- Autonolas
- Ritual

---

## Contributing

PRs and ideas welcome.

Open an issue if you'd like to experiment with **AI agent based prediction markets**.

---

## License

MIT
