{-# LANGUAGE ScopedTypeVariables #-}

-- | Specification of 'Pos.Block.Logic.Creation' module.

module Test.Pos.Block.Logic.CreationSpec
       ( spec
       ) where

import           Universum

import           Data.Default               (def)
import           Serokell.Data.Memory.Units (Byte, Gigabyte, convertUnit, fromBytes)
import           Test.Hspec                 (Spec, describe, runIO)
import           Test.Hspec.QuickCheck      (modifyMaxSuccess, prop)
import           Test.QuickCheck            (Gen, Property, Testable, arbitrary, choose,
                                             counterexample, elements, forAll, generate,
                                             listOf, listOf1, oneof, property)

import           Pos.Arbitrary.Block        ()
import           Pos.Arbitrary.Delegation   (genDlgPayload)
import           Pos.Arbitrary.Txp          (GoodTx, goodTxToTxAux)
import           Pos.Binary.Class           (biSize)
import           Pos.Block.Core             (BlockHeader, MainBlock)
import           Pos.Block.Logic            (RawPayload (..), createMainBlockPure)
import qualified Pos.Communication          ()
import           Pos.Constants              (genesisMaxBlockSize)
import           Pos.Core                   (HasCoreConstants, SlotId (..),
                                             blkSecurityParam, giveStaticConsts,
                                             unsafeMkLocalSlotIndex)
import           Pos.Crypto                 (SecretKey)
import           Pos.Delegation             (DlgPayload, ProxySKBlockInfo)
import           Pos.Ssc.Class              (Ssc (..), sscDefaultPayload)
import           Pos.Ssc.GodTossing         (GtPayload (..), SscGodTossing,
                                             commitmentMapEpochGen, mkVssCertificatesMap,
                                             vssCertificateEpochGen)
import           Pos.Txp.Core               (TxAux)
import           Pos.Update.Core            (UpdatePayload (..))
import           Pos.Util                   (SmallGenerator (..), makeSmall)

spec :: Spec
spec = giveStaticConsts $ describe "Block.Logic.Creation" $ do

    -- Sampling the minimum empty block size
    (sk0,prevHeader0) <- runIO $ generate arbitrary

    -- We multiply by 1.5 because there are different possible
    -- combinations of empty constructors and there's no out-of-box
    -- way to get maximum of them. Some settings produce 390b empty
    -- block, some -- 431b.
    let emptyBSize0 :: Byte
        emptyBSize0 = biSize (noSscBlock infLimit prevHeader0 [] def def sk0) -- in bytes
        emptyBSize :: Integral n => n
        emptyBSize = round $ (1.5 * fromIntegral emptyBSize0 :: Double)

    describe "createMainBlockPure" $ modifyMaxSuccess (const 1000) $ do
        prop "empty block size is sane" $ emptyBlk $ \blk0 -> leftToCounter blk0 $ \blk ->
            let s = biSize blk
            in counterexample ("Real block size: " <> show s <>
                               "\n\nBlock: " <> show blk) $
                 -- Various hashes and signatures in the block take 416
                 -- bytes; this is *completely* independent of encoding used.
                 -- Empirically, empty blocks don't get bigger than 550
                 -- bytes.
                 s <= 550 && s <= genesisMaxBlockSize
        prop "doesn't create blocks bigger than the limit" $
            forAll (choose (emptyBSize, emptyBSize * 10)) $ \(fromBytes -> limit) ->
            forAll arbitrary $ \(prevHeader, sk, updatePayload) ->
            forAll validGtPayloadGen $ \(gtPayload, slotId) ->
            forAll (genDlgPayload (siEpoch slotId)) $ \dlgPayload ->
            forAll (makeSmall $ listOf1 genTxAux) $ \txs ->
            let blk = producePureBlock limit prevHeader txs Nothing slotId
                                       dlgPayload gtPayload updatePayload sk
            in leftToCounter blk $ \b ->
                let s = biSize b
                in counterexample ("Real block size: " <> show s) $
                   s <= fromIntegral limit
        prop "removes transactions when necessary" $
            forAll arbitrary $ \(prevHeader, sk) ->
            forAll (makeSmall $ listOf1 genTxAux) $ \txs ->
            forAll (elements [0,0.5,0.9]) $ \(delta :: Double) ->
            let blk0 = noSscBlock infLimit prevHeader [] def def sk
                blk1 = noSscBlock infLimit prevHeader txs def def sk
            in leftToCounter ((,) <$> blk0 <*> blk1) $ \(b0, b1) ->
                let s = biSize b0 +
                        round ((fromIntegral $ biSize b1 - biSize b0) * delta)
                    blk2 = noSscBlock s prevHeader txs def def sk
                in counterexample ("Tested with block size limit: " <> show s) $
                   leftToCounter blk2 (const True)
        prop "strips ssc data when necessary" $
            forAll arbitrary $ \(prevHeader, sk) ->
            forAll validGtPayloadGen $ \(gtPayload, slotId) ->
            forAll (elements [0,0.5,0.9]) $ \(delta :: Double) ->
            let blk0 = producePureBlock infLimit prevHeader [] Nothing
                                        slotId def (defGTP slotId) def sk
                withPayload lim =
                    producePureBlock lim prevHeader [] Nothing slotId def gtPayload def sk
                blk1 = withPayload infLimit
            in leftToCounter ((,) <$> blk0 <*> blk1) $ \(b0,b1) ->
                let s = biSize b0 +
                        round ((fromIntegral $ biSize b1 - biSize b0) * delta)
                    blk2 = withPayload s
                in counterexample ("Tested with block size limit: " <> show s) $
                   leftToCounter blk2 (const True)
  where
    defGTP :: HasCoreConstants => SlotId -> GtPayload
    defGTP sId = sscDefaultPayload @SscGodTossing $ siSlot sId

    infLimit = convertUnit @Gigabyte @Byte 1

    leftToCounter :: (ToString s, Testable p) => Either s a -> (a -> p) -> Property
    leftToCounter x c = either (\t -> counterexample (toString t) False) (property . c) x

    emptyBlk :: (HasCoreConstants, Testable p) => (Either Text (MainBlock SscGodTossing) -> p) -> Property
    emptyBlk foo =
        forAll arbitrary $ \(prevHeader, sk, slotId) ->
        foo $ producePureBlock infLimit prevHeader [] Nothing slotId def (defGTP slotId) def sk

    genTxAux :: Gen TxAux
    genTxAux =
        goodTxToTxAux . getSmallGenerator <$> (arbitrary :: Gen (SmallGenerator GoodTx))

    noSscBlock
        :: HasCoreConstants
        => Byte
        -> BlockHeader SscGodTossing
        -> [TxAux]
        -> DlgPayload
        -> UpdatePayload
        -> SecretKey
        -> Either Text (MainBlock SscGodTossing)
    noSscBlock limit prevHeader txs proxyCerts updatePayload sk =
        let neutralSId = SlotId 0 (unsafeMkLocalSlotIndex $ fromIntegral $ blkSecurityParam * 2)
        in producePureBlock
            limit prevHeader txs Nothing neutralSId proxyCerts (defGTP neutralSId) updatePayload sk

    producePureBlock
        :: HasCoreConstants
        => Byte
        -> BlockHeader SscGodTossing
        -> [TxAux]
        -> ProxySKBlockInfo
        -> SlotId
        -> DlgPayload
        -> SscPayload SscGodTossing
        -> UpdatePayload
        -> SecretKey
        -> Either Text (MainBlock SscGodTossing)
    producePureBlock limit prev txs psk slot dlgPay sscPay usPay sk =
        createMainBlockPure limit prev psk slot sk $
        RawPayload txs sscPay dlgPay usPay

validGtPayloadGen :: HasCoreConstants => Gen (GtPayload, SlotId)
validGtPayloadGen = do
    vssCerts <- makeSmall $ fmap mkVssCertificatesMap $ listOf $ vssCertificateEpochGen 0
    let mkSlot i = SlotId 0 (unsafeMkLocalSlotIndex (fromIntegral i))
    oneof [ do commMap <- makeSmall $ commitmentMapEpochGen 0
               pure (CommitmentsPayload commMap vssCerts, SlotId 0 minBound)
          , do openingsMap <- makeSmall arbitrary
               pure (OpeningsPayload openingsMap vssCerts, mkSlot (4 * blkSecurityParam + 1))
          , do sharesMap <- makeSmall arbitrary
               pure (SharesPayload sharesMap vssCerts, mkSlot (8 * blkSecurityParam))
          , pure (CertificatesPayload vssCerts, mkSlot (7 * blkSecurityParam))
          ]
