# CallbackHandlerMorpho

## Overview

CallbackHandlerMorpho is a contract that handles callbacks from the Morpho protocol during supply and flash loan operations in the PlasmaVault system. It acts as a bridge between Morpho protocol callbacks and the PlasmaVault's internal callback handling system.

## Purpose

The contract serves two main purposes:

1. Handles supply callbacks from Morpho protocol
2. Handles flash loan callbacks from Morpho protocol

Both callbacks decode the provided data into a CallbackData structure that can be processed by the PlasmaVault system.

The CallbackData structure must always contain FuseActions that will be re-executed through PlasmaVault's executeInternal function. This mechanism ensures that any necessary actions during the callback are properly executed within the PlasmaVault's context and security boundaries.

## Integration with PlasmaVault

The CallbackHandlerMorpho is utilized in the PlasmaVault.sol contract through its fallback function. When the PlasmaVault executes FuseActions that interact with Morpho protocol, any callbacks from Morpho are processed through this handler.

Example flow:

1. PlasmaVault executes a FuseAction involving Morpho
2. Morpho protocol calls back to PlasmaVault
3. PlasmaVault's fallback function checks if execution is in progress
4. If execution is active, the callback is processed using CallbackHandlerLib
5. CallbackHandlerMorpho decodes the callback data for further processing
6. The decoded FuseActions from CallbackData are executed via PlasmaVault's executeInternal function
7. This re-execution allows for completing any necessary operations within the callback context

## Key Functions

### onMorphoSupply

Handles callbacks during supply operations to Morpho protocol.

-   ### onMorphoFlashLoan
-
-   Handles callbacks during flash loan operations from Morpho protocol. This function is called by Morpho after the flash loan funds have been transferred to the borrower but before they need to be repaid. The callback data must contain the FuseActions necessary to handle the borrowed funds and ensure proper repayment.
