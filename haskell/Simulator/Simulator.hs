module Simulator.Simulator (iteratedSimulation,
                            WireState,
                            initialWireState,
                            valueToList,
                            valueToInt) where

import Control.Arrow
import Control.Applicative
import Control.Monad
import Data.Array.IArray (Array)
import qualified Data.Array.IArray as Array
import Data.List
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.IntMap as IntMap
import Data.IntMap (IntMap)

import Netlist.AST
import Util.ListUtil
import Util.BinUtils

type WireState = Environment Value
type ROMs = Environment (Array Int [Bool]) -- immutable arrays
data Memory = Mem { registers :: Environment Value
                  , ram :: Environment (IntMap [Bool])
                  , rom :: ROMs
                  }
type Outputs = [(Ident, Value)]


extractArg :: WireState -> Arg -> Value
extractArg st (Avar i) = st Map.! i 
extractArg _  (Aconst v) = v

vLogic:: (Bool -> Bool -> Bool) -> Value -> Value -> Value
vLogic op (VBit a1) (VBit a2) = VBit $ op a1 a2

vNot :: Value -> Value
vNot (VBit a) = VBit $ not a

-- Partial function, doesn't handle memory
-- TODO (in the distant future): improve this with generic programming / SYB stuff
compute :: WireState -> Exp -> Value
compute st (Earg a) =
  extractArg st a
compute st (Enot a) =
  vNot . extractArg st $ a
compute st (Ebinop op a1 a2) =
  vLogic (binopFn op) vA1 vA2
  where vA1 = extractArg st a1
        vA2 = extractArg st a2 

compute st (Emux a1 a2 a3) =
  VBit $ if vA1 then vA3 else vA2
  where (VBit vA1) = extractArg st a1
        (VBit vA2) = extractArg st a2
        (VBit vA3) = extractArg st a3
compute st (Eselect i a) =
  VBit $ (valueToList $ extractArg st a) !! i
compute st (Eslice i1 i2 a) =
  VBitArray $ take (i2 - i1 + 1) . drop i1 . valueToList $ extractArg st a
compute st (Econcat a1 a2) =
  VBitArray $ valueToList vA1 ++ valueToList vA2
  where vA1 = extractArg st a1
        vA2 = extractArg st a2 


simulationStep :: Memory -> WireState -> Equation -> WireState
simulationStep memory oldWireState (ident, expr) =
  -- Using Map.Strict: (f expr) is evaluated strictly before inserting in the map
  let val = f expr in
  val `seq` Map.insert ident val oldWireState
  
  where f (Ereg _) = registers memory Map.! ident

        -- TODO: do something with addrSize?
        f (Erom addrSize wordSize readAddr)
           | wordSize == 1 = VBit . head $ word
           | otherwise = VBitArray word
          where
            wordAddr = valueToInt $ extractArg oldWireState readAddr
            word | wordAddr < addrMin ||
                   wordAddr > addrMax = replicate wordSize False
                 | otherwise = thisRom Array.! wordAddr
            (addrMin, addrMax) = Array.bounds thisRom
            thisRom = rom memory Map.! ident

        f (Eram addrSize wordSize readAddr writeEnable writeAddr writeData) 
           | wordSize == 1 = VBit . head $ word
           | otherwise = VBitArray word
          where
            wordAddr = valueToInt $ extractArg oldWireState readAddr
            word = case IntMap.lookup wordAddr (ram memory Map.! ident) of
                     Nothing -> replicate wordSize False
                     Just x  -> x

        -- purely combinational logic: just compute
        f e = compute oldWireState e
        
simulateCycle :: Program -> Memory -> WireState -- old memory + inputs
              -> (Memory, Outputs)
simulateCycle prog oldMem inputWires =
  (newMem &&& gatherOutputs)
  . foldl' (simulationStep oldMem) inputWires
  $ p_eqs prog
  where gatherOutputs finalWires =
          map (\i -> (i, finalWires Map.! i)) $ p_outputs prog
        newMem finalWires =
          newRegisters `seq` newRam `seq`
          oldMem { registers = newRegisters
                 , ram       = newRam }
          where getNewVal = second (finalWires Map.!)              
                newRegisters = Map.fromList . map getNewVal
                               $ programRegisters prog
                newRam = foldl' (\currentMap (ident,addr,datum) ->
                                  Map.adjust (IntMap.insert addr (valueToList datum))
                                  ident currentMap)
                         (ram oldMem)
                           (ramToUpdate prog finalWires)


initialWireState :: Program -- Sorted netlist
                 -> Environment Value -- Map of inputs
                 -> Maybe WireState -- outputs with possibility of error
                                    -- TODO: refine error signaling
initialWireState prog actualParams = foldM f Map.empty formalParams
  where formalParams = p_inputs prog
        f acc ident = do
          val <- Map.lookup ident actualParams
          guard . rightSize val $ p_vars prog Map.! ident   
          return $ Map.insert ident val acc
        rightSize (VBit _) TBit  = True
        rightSize (VBitArray a) (TBitArray n) = length a == n 
        rightSize _ _ = False

iteratedSimulation :: Program
                   -> Maybe [WireState]
                   -> Maybe (Environment [Bool])
                   -> [[(Ident, Value)]]
iteratedSimulation prog maybeInputs maybeROMs =
  -- Two cases:
  -- * if we have no input: simulate infinitely (with laziness)
  -- * if we're given a list of inputs: we simulate until the inputs run out
  -- TODO: ensure in the first case we have no inputs
  let inputWires = maybe (repeat Map.empty) id maybeInputs
      initialMemory = Mem { registers = initRegs,
                            ram = Map.fromList $ zip rams (repeat IntMap.empty), 
                            rom = maybe Map.empty initROMs maybeROMs }
  in trace (simulateCycle prog) initialMemory inputWires
  
  where initRegs = Map.fromList . flip zip (repeat (VBit False)) $ regs
        regs = map fst . filter isReg $ p_eqs prog
        rams = map fst . filter isRam $ p_eqs prog
        romSizes = Map.fromList [ (ident, (addrSize, wordSize))
                                | (ident, (Erom addrSize wordSize _)) <- p_eqs prog ]
        isRam (_, (Eram _ _ _ _ _ _)) = True
        isRam _ = False
        isReg (_, (Ereg _)) = True
        isReg _             = False
        initROMs = Map.mapWithKey initROM
        initROM ident bits = Array.listArray (0, romActualSize - 1) romContent
          where (addrSize, wordSize) = romSizes Map.! ident
                romContent = splits wordSize bits
                romActualSize = length romContent


programRegisters :: Program -> [(Ident, Ident)]
programRegisters = catMaybes . map p . p_eqs
  where p (x, (Ereg y)) = Just (x,y)
        p _             = Nothing
       
ramToUpdate :: Program -> WireState
            -> [(Ident, Int, Value)] -- Identifier, Position, Data to write  
ramToUpdate prog st = catMaybes . map extraction $ p_eqs prog 
  where extraction (ident,(Eram addrSize wordSize _ enable addrWrite datas ))=
          case (extractArg st enable) of 
            VBit True -> Just(ident,
                              valueToInt $ extractArg st addrWrite,
                              extractArg st datas) 
            _         -> Nothing
        extraction (_,_) = Nothing 

