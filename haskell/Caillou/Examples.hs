{-# LANGUAGE MultiParamTypeClasses, RecursiveDo #-}

module Examples where

import Control.Applicative
import Circuit

-- temporary for testing
import Simulation

halfAdd :: (Circuit m s) => (s,s) -> m (s,s)
halfAdd (a, b) = (,) <$> (a -^^- b) <*> (a -&&- b)

andLoop :: (SequentialCircuit m s) => s -> m s
andLoop inp = do rec out <- inp -&&- mem
                     mem <- delay out
                 return out
                 
