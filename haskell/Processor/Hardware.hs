{-# LANGUAGE MultiParamTypeClasses, DoRec #-}

module Processor.Hardware where

import Control.Applicative
import Control.Monad
import Data.List

import Caillou.NetlistGen
import Caillou.Arithmetic
import Caillou.Patterns
import Caillou.Circuit

import Netlist.AST
import Netlist.Print


-- Prolegomena and specifications --
------------------------------------

-- Size constants

import Processor.Parameters

-- Control signals / microcode specification

data ControlSignals s = CS { regRead   :: [s] -- 3 bits
                           , regWrite  :: [s] -- 3 bits
                           , writeFlag :: s   -- 1 bit
                           , writeTemp :: s   -- 1 bit
                           , muxData   :: s   -- 1 bit
                           , gcOpcode  :: [s] -- 2 bits
                           , aluCtrl   :: s   -- 1 bit
                           , useAlu    :: s   -- 1 bit
                           } --           Total: 13 bits (=microInstrS)
                        
decodeMicroInstruction :: [s] -> ControlSignals s
decodeMicroInstruction microinstr = CS rr rw wf wt md go ac ua
  where external = drop 2 microinstr -- first 2 bits are internal to control
        (rr,q0) = splitAt 3 external
        (rw,q1) = splitAt 3 q0
        (wf:q2) = q1
        (wt:q3) = q2
        (md:q4) = q3
        (go,q5) = splitAt 2 q4
        [ac,ua] = q5


-- Strong typing for the win!

newtype TagField  s = TagField  [s]
newtype DataField s = DataField [s]
newtype Word      s = Word      [s]
newtype Cons      s = Cons      [s]

-- Is there a way to make all this repetition nicer?

muxDataField :: (Circuit m s) => s -> DataField s -> DataField s -> m (DataField s)
muxDataField c (DataField xs) (DataField ys) = DataField <$> bigMux c xs ys

muxWord :: (Circuit m s) => s -> Word s -> Word s -> m (Word s)
muxWord c (Word xs) (Word ys) = Word <$> bigMux c xs ys

muxCons :: (Circuit m s) => s -> Cons s -> Cons s -> m (Cons s)
muxCons c (Cons xs) (Cons ys) = Cons <$> bigMux c xs ys

decomposeWord :: Word s -> (TagField s, DataField s)
decomposeWord (Word w) = (TagField prefix, DataField suffix)
  where (prefix, suffix) = splitAt tagS w

recomposeWord :: TagField s -> DataField s -> Word s
recomposeWord (TagField t) (DataField d) = Word $ t ++ d

decomposeCons :: Cons s -> (Word s, Word s)
decomposeCons (Cons w) = (Word prefix, Word suffix)
  where (prefix, suffix) = splitAt wordS w

recomposeCons :: Word s -> Word s -> Cons s
recomposeCons (Word t) (Word d) = Cons $ t ++ d


-- Global view of the processor --
----------------------------------

-- Plugging together the different functional blocks and control signals

processor :: (MemoryCircuit m s) => m [s]
processor = 
  do rec controlSignals <- control regOutTag

         regIn <- muxWord (muxData controlSignals) regOut
                  =<< muxWord (useAlu controlSignals)
                              (recomposeWord regOutTag alu)
                              gcOut
         gcOut <- memorySystem (gcOpcode controlSignals)
                               regOutData
                               regOut
                               tempOut
         tempOut <- singleRegister (writeTemp controlSignals) regIn
         
         alu <- miniAlu (aluCtrl controlSignals) (snd . decomposeWord $ gcOut)
         regOut <- registerArray controlSignals regIn
         let (regOutTag, regOutData) = decomposeWord regOut
     return []


-- Definitions for the functional blocks --
-------------------------------------------

-- Memory system (in charge of implementing alloc_cons, fetch_car, fetch_cdr)
-- Implementation 

memorySystem :: (MemoryCircuit m s) => [s] -> DataField s -> Word s -> Word s -> m (Word s)
memorySystem opCode (DataField ptr) regBus tempBus =
  do rec codeMem <- Cons <$> accessROM (dataS-1) cellS addrR
         dataMem <- Cons <$> accessRAM (dataS-1) cellS
                                       (addrR, allocCons, freeCounter,
                                       consRegTemp)
                             -- write to next free cell iff allocating
         freeCounter <- bigDelay =<< addBitToWord (allocCons, freeCounter)
     (car, cdr) <- decomposeCons <$> muxCons codeOrData codeMem dataMem
     muxWord carOrCdr car cdr
  where [carOrCdr, allocCons] = opCode
        (codeOrData:addrR) = ptr
        (Cons consRegTemp) = recomposeCons regBus tempBus


-- Testing equality to zero

isZero :: (Circuit m s) => [s] -> m s
isZero = neg <=< orAll
  --TODO : Check the code generated
  -- /!\ we can improve with a dichotomy
  where orAll  [a] = return a           
        orAll (t:q) = do out <- t -||> orAll q
                         return out 


-- A small ALU which can either increment or decrement its argument
        
miniAlu :: (SequentialCircuit m s) => s -> (DataField s) -> m (DataField s)
miniAlu incrOrDecr (DataField (t:q)) =
  do wireOne <- one
     wireZero <- zero
     DataField . fst <$> adder (wireZero, (wireOne,t):zip (repeat incrOrDecr) q)


-- Registers

-- The array of registers

registerArray :: (MemoryCircuit m s) => ControlSignals s -> Word s -> m (Word s)
registerArray controlSignals (Word regIn) = 
  Word <$> accessRAM 3 wordS (regRead   controlSignals,
                              writeFlag controlSignals,
                              regWrite  controlSignals,
                              regIn)
  
-- A single register (used for temp)

singleRegister :: (SequentialCircuit m s) => s -> Word s -> m (Word s)
singleRegister writeEnable (Word input) = do
  rec delays <- mapM delay newValue
      newValue <- zipWithM (\inp del -> mux3 (writeEnable, inp, del)) input delays
  return $ Word delays
  

-- The control logic
-- The microprogram is stored in a ROM, the function of the hardware
-- plumbing here is to handle state transitions

control :: (MemoryCircuit m s) => TagField s -> m (ControlSignals s)
control (TagField tag) =
  do wireZero <- zero
     let initialStateForTag = [wireZero] ++ tag
                              ++ replicate (microAddrS - tagS - 1) wireZero
     rec microInstruction <- accessROM microAddrS microInstrS mpc
         let (jump:dispatchOnTag:suffix) = microInstruction
         nextAddr <- incrementer mpc
         -- maybe replace by a mux between 3 alternatives ?
         mpc <- bigDelay newMpc
         newMpc <- bigDoubleMux [jump, dispatchOnTag]
                                nextAddr
                                (take microAddrS suffix)
                                initialStateForTag
                                initialStateForTag
     notJump <- neg jump
     neutralized <- mapM (notJump -&&-) microInstruction
     return $ decodeMicroInstruction neutralized


-- Output netlist
-- TODO: improve and put in another file
main :: IO ()
main = do
  let inp = (Avar "iod", DataField [ Avar $ "i" ++ show k | k <- [0..(dataS-1)] ])
      circ (a,b) = miniAlu a b
      (_,nl,_) = synthesizeBarebonesNetlist circ inp
  writeFile "foobar.net" . unlines . map show $ nl

