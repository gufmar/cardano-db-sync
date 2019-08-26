{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Explorer.Node.Insert.Genesis
  ( insertValidateGenesisDistribution
  , validateGenesisDistribution
  ) where

import           Cardano.Prelude

import qualified Cardano.Crypto as Crypto

import           Cardano.BM.Trace (Trace, logInfo)
import qualified Cardano.Chain.Common as Ledger
import qualified Cardano.Chain.Genesis as Ledger
import qualified Cardano.Chain.UTxO as Ledger

import           Control.Monad (void)
import           Control.Monad.IO.Class (MonadIO)
import           Control.Monad.Trans.Reader (ReaderT)

import           Data.Coerce (coerce)
import qualified Data.Map.Strict as Map
import           Data.Text (Text)
import qualified Data.Text as Text

import           Database.Persist.Sql (SqlBackend)

import qualified Explorer.DB as DB
import           Explorer.Node.Util

-- | Idempotent insert the initial Genesis distribution transactions into the DB.
-- If these transactions are already in the DB, they are validated.
insertValidateGenesisDistribution :: Trace IO Text -> Ledger.Config -> IO ()
insertValidateGenesisDistribution tracer cfg = do
    -- TODO: This is idempotent, but probably better to check if its already been done
    -- and validate if it has.
    -- This is how logging is turned on and off.
    -- The logging is incredibly verbose and probably only useful for debugging.
    if False
      then DB.runDbIohkLogging tracer insertAction
      else DB.runDbNoLogging insertAction
    logInfo tracer $ "Initial genesis distribution populated. Hash "
                    <> renderAbstractHash (configGenesisHash cfg)
  where
    insertAction :: MonadIO m => ReaderT SqlBackend m ()
    insertAction = do
        -- Insert an 'artificial' Genesis block.
        bid <- DB.insertBlock $
                  DB.Block
                    { DB.blockHash = configGenesisHash cfg
                    , DB.blockSlotNo = Nothing
                    , DB.blockBlockNo = 0
                    , DB.blockPrevious = Nothing
                    , DB.blockMerkelRoot = Nothing
                    , DB.blockSize = 0
                    }

        mapM_ (insertTxOuts bid) $ genesisTxos cfg

        supply <- DB.queryTotalSupply
        liftIO $ logInfo tracer ("Total genesis supply of lovelace: " <> textShow supply)

-- | Validate that the initial Genesis distribution in the DB matches the Genesis data.
validateGenesisDistribution :: Trace IO Text -> Ledger.Config -> IO ()
validateGenesisDistribution tracer cfg =
    if False
      then DB.runDbIohkLogging tracer validateAction
      else DB.runDbNoLogging validateAction
  where
    validateAction :: MonadIO m => ReaderT SqlBackend m ()
    validateAction = do
      mbid <- DB.queryBlockId $ configGenesisHash cfg
      case mbid of
        Left err -> panic $ "validateGenesisDistribution: Not able to find genesis "
                            <> DB.renderLookupFail err
        Right bid -> validateGenesisBlock bid

    -- Not really a block, but all the genesis distribution need to be associated with
    -- an pseudo block.
    validateGenesisBlock :: MonadIO m => DB.BlockId -> ReaderT SqlBackend m ()
    validateGenesisBlock bid = do
      txCount <- DB.queryBlockTxCount bid
      let expectedTxCount = fromIntegral $length (genesisTxos cfg)
      when (txCount /= expectedTxCount) $
        panic $ Text.concat
                [ "validateGenesisDistribution: Expected initial block to have "
                , textShow expectedTxCount
                , " but got "
                , textShow txCount
                ]
      totalSupply <- DB.queryTotalSupply
      case configGenesisSupply cfg of
        Left err -> panic $ "validateGenesisDistribution: " <> textShow err
        Right expectedSupply ->
          when (expectedSupply /= totalSupply) $
            panic $ Text.concat
                    [ "validateGenesisDistribution: Expected total supply to be "
                    , textShow expectedSupply
                    , " but got "
                    , textShow totalSupply
                    ]

-- -----------------------------------------------------------------------------

insertTxOuts :: MonadIO m => DB.BlockId -> (Ledger.Address, Ledger.Lovelace) -> ReaderT SqlBackend m ()
insertTxOuts blkId (address, value) = do
  -- Each address/value pair of the initial coin distribution comes from an artifical transaction
  -- with a hash generated by hashing the address.
  txId <- DB.insertTx $
            DB.Tx
              { DB.txHash = unTxHash $ txHashOfAddress address
              , DB.txBlock = blkId
              , DB.txFee = 0
              }
  void . DB.insertTxOut $
            DB.TxOut
              { DB.txOutTxId = txId
              , DB.txOutIndex = 0
              , DB.txOutAddress = unAddressHash $ Ledger.addrRoot address
              , DB.txOutValue = Ledger.unsafeGetLovelace value
              }

-- -----------------------------------------------------------------------------

configGenesisHash :: Ledger.Config -> ByteString
configGenesisHash =
  unAbstractHash . Ledger.unGenesisHash . Ledger.configGenesisHash

configGenesisSupply :: Ledger.Config -> Either Ledger.LovelaceError Word64
configGenesisSupply =
  fmap Ledger.unsafeGetLovelace . Ledger.sumLovelace . map snd . genesisTxos

genesisTxos :: Ledger.Config -> [(Ledger.Address, Ledger.Lovelace)]
genesisTxos config =
    avvmBalances <> nonAvvmBalances
  where
    avvmBalances :: [(Ledger.Address, Ledger.Lovelace)]
    avvmBalances =
      first (Ledger.makeRedeemAddress networkMagic)
        <$> Map.toList (Ledger.unGenesisAvvmBalances $ Ledger.configAvvmDistr config)

    networkMagic :: Ledger.NetworkMagic
    networkMagic = Ledger.makeNetworkMagic (Ledger.configProtocolMagic config)

    nonAvvmBalances :: [(Ledger.Address, Ledger.Lovelace)]
    nonAvvmBalances =
      Map.toList $ Ledger.unGenesisNonAvvmBalances (Ledger.configNonAvvmBalances config)

txHashOfAddress :: Ledger.Address -> Crypto.Hash Ledger.Tx
txHashOfAddress = coerce . Crypto.hash