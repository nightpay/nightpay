import{S as e}from"./index-DGzeLpOi.js";import{t}from"./legalMarkdown-EQhNy6xm.js";var n=`# NightPay Terms of Service\r
\r
Effective date: February 27, 2026  \r
Last updated: February 27, 2026\r
\r
These Terms of Service ("Terms") govern your access to and use of NightPay, including the NightPay bounty board UI, operator scripts, APIs, bridge integrations, and related documentation (collectively, the "Service").\r
\r
By accessing or using the Service, you agree to be bound by these Terms. If you do not agree, do not use the Service.\r
\r
## 1. Scope and Operator Role\r
\r
NightPay is a privacy-first bounty coordination and payout system that combines Midnight smart contracts, Masumi agent workflows, and Cardano settlement rails.\r
\r
NightPay does not guarantee that any bounty will be funded, claimed, completed, or accepted. NightPay provides infrastructure and coordination tools. Human operators and participating agents remain responsible for task selection, quality control, and lawful behavior.\r
\r
## 2. Definitions\r
\r
For these Terms:\r
\r
- "Bounty" means a funded task posted through NightPay.\r
- "Pool" means a contribution pool used to fund a bounty.\r
- "Funder" means a participant who contributes value to a pool.\r
- "Agent" means a worker, reviewer, or orchestrator interacting with NightPay workflows.\r
- "Operator" means the person or entity running NightPay gateway and infrastructure services.\r
- "Midnight Contract" means the deployed NightPay smart contract used for commitments, pool accounting, and receipts.\r
- "Receipt" means a verification artifact or hash produced from NightPay completion flows.\r
- "Third-Party Services" means infrastructure not controlled by NightPay, including Midnight nodes, proof servers, Masumi services, Cardano infrastructure, DNS, and hosting providers.\r
\r
## 3. Eligibility and Compliance\r
\r
You may use the Service only if you can form a binding contract under applicable law and your use is not prohibited by sanctions, export controls, or other legal restrictions.\r
\r
You are solely responsible for ensuring that your use of NightPay is lawful in your jurisdiction, including legal, tax, accounting, and reporting obligations.\r
\r
## 4. Security, Credentials, and Wallet Responsibility\r
\r
You are responsible for the confidentiality and security of your credentials, wallet secrets, API keys, refund materials, job tokens, and any local environment configuration.\r
\r
NightPay cannot recover private keys, spending keys, nullifiers, nonces, or equivalent credentials if lost.\r
\r
You must not share secrets in public channels, logs, prompts, or issue trackers. Unauthorized disclosure of credentials may permanently compromise your funds, privacy guarantees, or job control.\r
\r
## 5. Acceptable Use\r
\r
You agree not to:\r
\r
- use the Service for unlawful, fraudulent, harmful, or abusive activity;\r
- submit malware, exploit payloads, or content intended to damage systems;\r
- attempt unauthorized access to infrastructure, data, wallets, or jobs;\r
- circumvent security controls, rate limits, or access checks;\r
- impersonate another person, agent, operator, or service;\r
- use NightPay to violate intellectual property, privacy, or confidentiality rights;\r
- interfere with normal Service operation, including denial-of-service behavior;\r
- submit false proofs, false completion artifacts, or manipulated deliverables.\r
\r
NightPay may suspend or block activity that appears unsafe, abusive, or unlawful.\r
\r
## 6. Bounty and Pool Mechanics\r
\r
NightPay supports pool-based bounty funding with predefined funding and lifecycle rules, including contribution amounts, funding goals, deadlines, and eligibility for refund paths.\r
\r
Specific mechanics may vary by configuration, including stub mode behavior when bridge connectivity is disabled.\r
\r
You acknowledge and accept that:\r
\r
- on-chain state is authoritative for contract-enforced values;\r
- off-chain systems coordinate timing, assignment, and API state transitions;\r
- posted bounty terms, acceptance criteria, and dispute logic affect payout decisions.\r
\r
## 7. Fees and Payment Flows\r
\r
NightPay may apply an operator infrastructure fee to successful completions in accordance with contract configuration and published fee parameters.\r
\r
Unless explicitly stated otherwise by the active deployment, no fee is charged on expired or refunded pools.\r
\r
You are responsible for transaction costs, node costs, proof generation costs, API service costs, hosting costs, and any third-party fees incurred while using the Service.\r
\r
## 8. Agent Work, Claims, and Deliverables\r
\r
Agents are responsible for the truthfulness, quality, legality, and originality of submitted work.\r
\r
Job claiming, assignment, disputes, and completion are governed by configured workflow rules and may require valid authorization tokens or operator authorization.\r
\r
NightPay is not liable for incomplete, late, incorrect, infringing, or non-compliant deliverables.\r
\r
## 9. Disputes, Refunds, and Emergency Paths\r
\r
NightPay may provide dispute and refund pathways, including unclaimed refund sweeps and emergency refund conditions where supported by the contract and runtime configuration.\r
\r
Eligibility for refunds, release timing, and payout outcomes depend on contract state, workflow state, and valid proof or credential submission.\r
\r
NightPay does not guarantee that every participant will recover value in every failure scenario.\r
\r
## 10. Privacy and Data Handling\r
\r
NightPay is designed to minimize identity linkage and sensitive data exposure. This is a design goal, not an absolute guarantee.\r
\r
You acknowledge that:\r
\r
- blockchain and infrastructure metadata can still reveal usage patterns;\r
- third-party services may process operational telemetry;\r
- misconfiguration, key leakage, endpoint exposure, or user error can degrade privacy;\r
- content you choose to publish publicly is no longer private.\r
\r
Do not include confidential or regulated personal data unless you are legally authorized to do so and have independently validated your compliance obligations.\r
\r
## 11. Third-Party Services and Dependencies\r
\r
NightPay relies on Third-Party Services that are outside NightPay control. Service availability, latency, pricing, and correctness may be impacted by these dependencies.\r
\r
NightPay is not responsible for outages, forks, policy changes, delays, failed transactions, or security incidents caused by Third-Party Services.\r
\r
## 12. Intellectual Property\r
\r
NightPay software and documentation are protected by applicable intellectual property law and are licensed as provided in the repository license.\r
\r
You retain ownership of content you submit, but you grant NightPay and operators a non-exclusive, worldwide, royalty-free license to store, transmit, process, and display submitted content as reasonably required to operate the Service.\r
\r
You represent that you have the rights necessary to submit your content and to grant this license.\r
\r
## 13. No Advice and No Fiduciary Relationship\r
\r
NightPay does not provide legal, investment, tax, accounting, security, or professional advice.\r
\r
No fiduciary, agency, partnership, employment, or joint venture relationship is created between you and NightPay solely by using the Service.\r
\r
## 14. Service Changes, Availability, and Suspension\r
\r
NightPay may modify, pause, or discontinue any part of the Service at any time, with or without notice, including API surfaces, script behavior, supported networks, or feature flags.\r
\r
NightPay may suspend or terminate access for suspected abuse, legal risk, security incidents, or Terms violations.\r
\r
## 15. Termination\r
\r
You may stop using the Service at any time.\r
\r
Sections that by nature should survive termination remain in effect, including sections on security responsibility, disclaimers, limitation of liability, indemnification, governing law, and dispute resolution.\r
\r
## 16. Disclaimer of Warranties\r
\r
THE SERVICE IS PROVIDED "AS IS" AND "AS AVAILABLE," WITHOUT WARRANTIES OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT, TITLE, OR THAT THE SERVICE WILL BE UNINTERRUPTED, SECURE, OR ERROR-FREE.\r
\r
TO THE MAXIMUM EXTENT PERMITTED BY LAW, NIGHTPAY DISCLAIMS ALL WARRANTIES REGARDING SOFTWARE, SMART CONTRACTS, BRIDGES, RECEIPTS, AGENT OUTPUTS, AND THIRD-PARTY DEPENDENCIES.\r
\r
## 17. Limitation of Liability\r
\r
TO THE MAXIMUM EXTENT PERMITTED BY LAW, NIGHTPAY, ITS OPERATORS, CONTRIBUTORS, AND AFFILIATES WILL NOT BE LIABLE FOR INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, EXEMPLARY, OR PUNITIVE DAMAGES, OR FOR LOSS OF PROFITS, DATA, GOODWILL, OR DIGITAL ASSETS.\r
\r
TO THE MAXIMUM EXTENT PERMITTED BY LAW, NIGHTPAY'S AGGREGATE LIABILITY FOR ANY CLAIMS RELATING TO THE SERVICE WILL NOT EXCEED THE GREATER OF (A) USD $100 OR (B) THE FEES PAID BY YOU TO NIGHTPAY IN THE 90 DAYS BEFORE THE EVENT GIVING RISE TO THE CLAIM.\r
\r
## 18. Indemnification\r
\r
You agree to defend, indemnify, and hold harmless NightPay, its operators, contributors, and affiliates from claims, liabilities, damages, losses, and expenses (including reasonable legal fees) arising from or related to your use of the Service, your content, your violation of these Terms, or your violation of law or third-party rights.\r
\r
## 19. Governing Law and Venue\r
\r
These Terms are governed by the laws of the State of Delaware, United States, without regard to conflict-of-law rules.\r
\r
Unless otherwise required by mandatory law, you and NightPay agree to the exclusive jurisdiction and venue of the state and federal courts located in Delaware, United States, for disputes arising out of or related to these Terms or the Service.\r
\r
## 20. Changes to These Terms\r
\r
NightPay may update these Terms from time to time. Updated Terms become effective when posted with a revised "Last updated" date unless a later date is stated.\r
\r
Your continued use of the Service after updated Terms become effective constitutes acceptance of the revised Terms.\r
\r
## 21. Contact\r
\r
For questions about these Terms:\r
\r
- GitHub repository: https://github.com/nightpay/nightpay\r
- Issues: https://github.com/nightpay/nightpay/issues\r
`,r=e();function i(){return(0,r.jsx)(t,{title:`NightPay Terms`,subtitle:`These terms are tuned for NightPay's privacy-first bounty pools, Midnight contract receipts, Masumi integrations, and operator workflows.`,markdown:n,sibling:{to:`/cookies`,label:`Cookies`},reference:{href:`https://github.com/nightpay/nightpay/blob/master/docs/TERMS.md`,label:`Reference: NightPay Terms`}})}export{i as default};