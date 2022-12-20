// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.17;

import "../interfaces/IOracleManager.sol";

/// @title Chainlink oracle manager implementation
/// @notice Manages prices provided by a Chainlink aggregate price feed.
/// @author float
contract OracleManager is IOracleManager {
  /*╔═════════════════════════════╗
    ║        Global state         ║
    ╚═════════════════════════════╝*/

  /// @notice Chainlink oracle contract
  AggregatorV3Interface public immutable override chainlinkOracle;

  /// @notice Timestamp that epoch 0 started at
  uint256 public immutable initialEpochStartTimestamp;

  /// @notice Least amount of time needed to wait after epoch end time for the oracle price to be valid to execute that epoch
  /// @dev  This value can only be upgraded via contract upgrade
  uint256 public immutable MINIMUM_EXECUTION_WAIT_THRESHOLD;

  /// @notice Length of the epoch for this market, in seconds
  /// @dev No mechanism exists currently to upgrade this value. Additional contract work+testing needed to make this have flexibility.
  uint256 public immutable EPOCH_LENGTH;

  /// @notice Phase ID to last round ID of the associated aggregator
  mapping(uint16 => uint80) public roundIdOfLastPriceBeforePhaseStart;

  /*╔═════════════════════════════╗
    ║           ERRORS            ║
    ╚═════════════════════════════╝*/

  /// @notice Thrown when no phase ID is in the mapping
  error roundIdOfLastPriceBeforePhaseStartBeforePhaseStartNotSet(uint16 phaseId);

  /*╔═════════════════════════════╗
    ║        Construction         ║
    ╚═════════════════════════════╝*/

  constructor(
    address _chainlinkOracle,
    uint256 epochLength,
    uint256 minimumExecutionWaitThreshold
  ) {
    chainlinkOracle = AggregatorV3Interface(_chainlinkOracle);
    MINIMUM_EXECUTION_WAIT_THRESHOLD = minimumExecutionWaitThreshold;
    EPOCH_LENGTH = epochLength;

    // NOTE: along with the getCurrentEpochIndex function this assignment gives an initial epoch index of 1,
    //         and this is set at the time of deployment of this contract
    //         i.e. calling getCurrentEpochIndex() at the end of this constructor will give a value of 1.
    initialEpochStartTimestamp = getEpochStartTimestamp() - epochLength;
  }

  /*╔═════════════════════════════╗
    ║          roundIdOfLastPriceBeforePhaseStart        ║
    ╚═════════════════════════════╝*/

  /// @notice This is required in the case that the price for an epoch update is the 1st price in a new chainlink phase.
  /// @dev This function can be called by anyone - and is public.
  /// @param _phaseId Phase id of the last roundId to set for backwards price search.
  /// @param _lastAggregatorRoundId aggregatorRoundId of the last roundId to set for backwards price search.
  /// @param consecutiveEmptyPhases The number of consecutive empty phases after the last roundId to set - this will typicaly be 0, but is needed in the case that chainlink have an empty phase change.
  function setRoundIdOfLastPriceBeforePhaseStart(
    uint16 _phaseId,
    uint64 _lastAggregatorRoundId,
    uint16 consecutiveEmptyPhases
  ) external {
    // Check that the consecutive empty phases after last phase to set are really empty
    for (uint256 i = 1; i <= consecutiveEmptyPhases; i++) {
      (, , uint256 emptyPhaseTimestamp, , ) = chainlinkOracle.getRoundData((uint80(_phaseId + i) << 64) + 1);
      require(emptyPhaseTimestamp == 0, "Phase is not empty");
    }

    // Check that there is a valid price in the next phase
    (, , uint256 nextPhaseTimestamp, , ) = chainlinkOracle.getRoundData((uint80(_phaseId + consecutiveEmptyPhases + 1) << 64) + 1);
    require(nextPhaseTimestamp != 0, "Phase is empty");

    uint80 previousValidRoundId = uint80((uint256(_phaseId) << 64) | _lastAggregatorRoundId);

    // Check that the last price on the phase of the given roundId hasn't been set.
    (, , uint256 nextTimestampOnCurrentPhase, , ) = chainlinkOracle.getRoundData(previousValidRoundId + 1);
    require(nextTimestampOnCurrentPhase == 0, "incorrect phase change passed");

    // Check that thp price on the given roundId is valid
    (, int256 price, uint256 lastUpdateOnPhaseTimestamp, , ) = chainlinkOracle.getRoundData(previousValidRoundId);
    require(lastUpdateOnPhaseTimestamp > 0 && price > 0, "incorrect phase change passed");

    // Here we set the last round ID of that phase backwards since this is how the `validateAndReturnMissedEpochInformation` function searches for prices
    roundIdOfLastPriceBeforePhaseStart[_phaseId + consecutiveEmptyPhases + 1] = previousValidRoundId;
  }

  /*╔═════════════════════════════╗
    ║          Helpers            ║
    ╚═════════════════════════════╝*/

  /// @notice Returns start timestamp of current epoch
  /// @return getEpochStartTimestamp start timestamp of the current epoch
  function getEpochStartTimestamp() public view returns (uint256) {
    //Eg. If EPOCH_LENGTH is 10min, then the epoch will change at 11:00, 11:10, 11:20 etc.
    // NOTE: we intentianally divide first to truncate the insignificant digits.
    //slither-disable-next-line divide-before-multiply
    return (block.timestamp / EPOCH_LENGTH) * EPOCH_LENGTH;
  }

  /// @notice Returns index of the current epoch based on block.timestamp
  /// @dev Called by internal functions to get current epoch index
  /// @return getCurrentEpochIndex the current epoch index
  //slither-disable-next-line block-timestamp
  function getCurrentEpochIndex() external view returns (uint256) {
    return (getEpochStartTimestamp() - initialEpochStartTimestamp) / EPOCH_LENGTH;
  }

  /*╔═════════════════════════════╗
    ║    Validator and Fetcher    ║
    ╚═════════════════════════════╝*/

  /// @notice Check that the given array of oracle prices are valid for the epochs that need executing
  /// @param latestExecutedEpochIndex The index of the epoch that was last executed
  /// @param oracleRoundIdsToExecute Array of roundIds to be validated
  /// @return missedEpochPriceUpdates Array of prices to be used for epoch execution
  function validateAndReturnMissedEpochInformation(uint32 latestExecutedEpochIndex, uint80[] memory oracleRoundIdsToExecute)
    public
    view
    returns (int256[] memory missedEpochPriceUpdates)
  {
    uint256 lengthOfEpochsToExecute = oracleRoundIdsToExecute.length;

    if (lengthOfEpochsToExecute == 0) revert EmptyArrayOfIndexes();

    // (, previousPrice, , , ) = chainlinkOracle.getRoundData(latestExecutedOracleRoundId);

    missedEpochPriceUpdates = new int256[](lengthOfEpochsToExecute);

    // This value is used to determine the time boundary from which a price is valid to execute an epoch.
    // Given we are looking to execute epoch n, this value will be timestamp of epoch n+1 + MEWT,
    // The price will need to fall between (epoch n+1 + MEWT , epoch n+2 + MEWT) and also be the
    // the first price within that time frame to be valid. See link below for visual
    // https://app.excalidraw.com/l/2big5WYTyfh/4PhAp1a28s1
    uint256 relevantEpochStartTimestampWithMEWT = ((uint256(latestExecutedEpochIndex) + 2) * EPOCH_LENGTH) +
      MINIMUM_EXECUTION_WAIT_THRESHOLD +
      initialEpochStartTimestamp;

    for (uint32 i = 0; i < lengthOfEpochsToExecute; i++) {
      // Get correct data
      (, int256 currentOraclePrice, uint256 currentOracleUpdateTimestamp, , ) = chainlinkOracle.getRoundData(oracleRoundIdsToExecute[i]);

      // Get Previous round data to validate correctness.
      (, , uint256 previousOracleUpdateTimestamp, , ) = chainlinkOracle.getRoundData(oracleRoundIdsToExecute[i] - 1);

      // Breakdown of the below check:
      //  - the previous oracle timestamp was zero
      //  &&
      //  - the previous price was from a previous phase. The previous price is from a previous phase if the aggregatorRoundId is 1 (since it is the first round)
      if (previousOracleUpdateTimestamp == 0 && ((oracleRoundIdsToExecute[i] << 16) >> 16) == 1) {
        // NOTE: if the phase changes, then we want to correct the phase of the update.
        //       There is no guarantee that the phaseID won't increase multiple times in a short period of time (hence the while loop).
        //       But chainlink does promise that it will be sequential.
        // View how phase changes happen here: https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.7/dev/AggregatorProxy.sol#L335
        uint16 newPhaseId = uint16(oracleRoundIdsToExecute[i] >> 64);
        if (roundIdOfLastPriceBeforePhaseStart[newPhaseId] != 0) {
          // NOTE: re-using this variable to keep gas costs low for this edge case.
          (, , previousOracleUpdateTimestamp, , ) = chainlinkOracle.getRoundData(roundIdOfLastPriceBeforePhaseStart[newPhaseId]);
          assert(previousOracleUpdateTimestamp != 0);
        } else {
          revert roundIdOfLastPriceBeforePhaseStartBeforePhaseStartNotSet({phaseId: newPhaseId});
        }
      }

      // This checks the price given is valid and falls within the correct window.
      // see https://app.excalidraw.com/l/2big5WYTyfh/4PhAp1a28s1
      if (
        previousOracleUpdateTimestamp >= relevantEpochStartTimestampWithMEWT ||
        currentOracleUpdateTimestamp < relevantEpochStartTimestampWithMEWT ||
        currentOracleUpdateTimestamp >= relevantEpochStartTimestampWithMEWT + EPOCH_LENGTH
      ) revert InvalidOracleExecutionRoundId({oracleRoundId: oracleRoundIdsToExecute[i]});

      if (currentOraclePrice <= 0) revert InvalidOraclePrice({oraclePrice: currentOraclePrice});

      missedEpochPriceUpdates[i] = currentOraclePrice;

      relevantEpochStartTimestampWithMEWT += EPOCH_LENGTH;
    }
  }
}
