import {TransactionReceipt} from '@ethersproject/abstract-provider/src.ts/index'
import {ethers} from 'hardhat'

export async function deployBitDao(admin: string): Promise<TransactionReceipt> {
  const erc20Factory = await ethers.getContractFactory('BitDAO')
  const erc20 = await erc20Factory.deploy(admin)
  return erc20.deployTransaction.wait()
}

export async function deployGovernance(
  erc20: string,
  timelock: string
): Promise<TransactionReceipt> {
  const Governance = await ethers.getContractFactory('Governance')
  const aggregate = await Governance.deploy(erc20, timelock)
  return aggregate.deployTransaction.wait()
}

export async function deployTimeLockController(
  admin: string
): Promise<TransactionReceipt> {
  const TimelockController = await ethers.getContractFactory(
    'TimelockController'
  )
  const timelock = await TimelockController.deploy(1, [admin], [admin])
  return timelock.deployTransaction.wait()
}

export async function deployMulticall(): Promise<TransactionReceipt> {
  const Multicall = await ethers.getContractFactory('Multicall')
  const aggregate = await Multicall.deploy()
  return aggregate.deployTransaction.wait()
}
