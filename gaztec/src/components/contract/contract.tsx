import { css } from "@emotion/react";
import { useDropzone } from "react-dropzone";
import "./dropzone.css";
import { useContext, useEffect, useState } from "react";
import {
  AuthWitness,
  Contract,
  ContractArtifact,
  ContractInstanceWithAddress,
  loadContractArtifact,
} from "@aztec/aztec.js";
import { AztecContext } from "../home/home";
import {
  Button,
  Card,
  CardActions,
  CardContent,
  Checkbox,
  CircularProgress,
  FormControlLabel,
  FormGroup,
  IconButton,
  Input,
  InputAdornment,
  Typography,
} from "@mui/material";
import FindInPageIcon from "@mui/icons-material/FindInPage";
import { prepTx } from "../../utils/interactions";
import { formatFrAsString } from "../../utils/conversion";
import { DeployContractDialog } from "./components/deployContractDialog";
import { FunctionParameter } from "../common/fnParameter";
import ClearIcon from "@mui/icons-material/Clear";
import { RegisterContractDialog } from "./components/registerContractDialog";
import { CopyToClipboardButton } from "../common/copyToClipboardButton";
import VpnKeyIcon from "@mui/icons-material/VpnKey";
import SendIcon from "@mui/icons-material/Send";
import PsychologyIcon from "@mui/icons-material/Psychology";
import { CreateAuthwitDialog } from "./components/createAuthwitDialog";

const container = css({
  display: "flex",
  height: "100vh",
  width: "75vw",
  overflow: "hidden",
  justifyContent: "center",
  alignItems: "center",
});

const dropZoneContainer = css({
  display: "flex",
  flexDirection: "column",
  width: "100%",
  height: "80%",
  border: "5px dashed black",
  borderRadius: "15px",
  margin: "5rem",
});

const contractFnContainer = css({
  display: "block",
  width: "100%",
  overflowY: "auto",
  color: "black",
  height: "100%",
});

const header = css({
  display: "flex",
  alignItems: "center",
  margin: "0 1rem",
  padding: "1rem",
});

const simulationContainer = css({
  display: "flex",
  flexDirection: "row",
  alignItems: "center",
});

const checkBoxLabel = css({
  height: "1.5rem",
});

const FORBIDDEN_FUNCTIONS = [
  "process_log",
  "compute_note_hash_and_optionally_a_nullifier",
  "sync_notes",
];

export function ContractComponent() {
  const [contractArtifact, setContractArtifact] =
    useState<ContractArtifact | null>(null);

  const [filters, setFilters] = useState({
    searchTerm: "",
    private: true,
    public: true,
    unconstrained: true,
  });

  const [isWorking, setIsWorking] = useState(false);

  const [simulationResults, setSimulationResults] = useState({});
  const [parameters, setParameters] = useState({});

  const [openDeployContractDialog, setOpenDeployContractDialog] =
    useState(false);
  const [openRegisterContractDialog, setOpenRegisterContractDialog] =
    useState(false);
  const [openCreateAuthwitDialog, setOpenCreateAuthwitDialog] = useState(false);
  const [authwitFnData, setAuthwitFnData] = useState({
    name: "",
    parameters: [],
    isPrivate: false,
  });

  const {
    wallet,
    walletDB,
    currentContract,
    setCurrentContract,
    setCurrentTx,
  } = useContext(AztecContext);

  useEffect(() => {
    if (currentContract) {
      setContractArtifact(currentContract.artifact);
      setFilters({
        searchTerm: "",
        private: true,
        public: true,
        unconstrained: true,
      });
    }
  }, [currentContract]);

  const { getRootProps, getInputProps } = useDropzone({
    onDrop: async (files) => {
      const file = files[0];
      const reader = new FileReader();
      reader.onload = async (e) => {
        const contractArtifact = loadContractArtifact(
          JSON.parse(e.target?.result as string)
        );
        setContractArtifact(contractArtifact);
      };
      reader.readAsText(file);
    },
  });

  const handleParameterChange = (fnName: string, index: number, value: any) => {
    const fnParameters = parameters[fnName] || [];
    fnParameters[index] = value;
    setParameters({ ...parameters, [fnName]: fnParameters });
  };

  const handleContractCreation = async (
    contract?: ContractInstanceWithAddress,
    alias?: string
  ) => {
    if (contract && alias) {
      await walletDB.storeContract(
        contract.address,
        contractArtifact,
        undefined,
        alias
      );
      setCurrentContract(
        await Contract.at(contract.address, contractArtifact, wallet)
      );
    }
    setOpenDeployContractDialog(false);
    setOpenRegisterContractDialog(false);
  };

  const simulate = async (fnName: string) => {
    setIsWorking(true);
    let result;
    try {
      const { encodedArgs } = await prepTx(
        contractArtifact,
        fnName,
        parameters[fnName]
      );
      const call = currentContract.methods[fnName](...encodedArgs);

      result = await call.simulate();
      setSimulationResults({
        ...simulationResults,
        ...{ [fnName]: { success: true, data: result } },
      });
    } catch (e) {
      setSimulationResults({
        ...simulationResults,
        ...{ [fnName]: { success: false, error: e.message } },
      });
    }

    setIsWorking(false);
  };

  const send = async (fnName: string) => {
    setIsWorking(true);
    let receipt;
    let txHash;
    const currentTx = {
      status: "proving" as const,
      fnName: fnName,
      contractAddress: currentContract.address,
    };
    setCurrentTx(currentTx);
    try {
      const { encodedArgs } = await prepTx(
        contractArtifact,
        fnName,
        parameters[fnName]
      );
      const call = currentContract.methods[fnName](...encodedArgs);

      const provenCall = await call.prove();
      txHash = provenCall.getTxHash();
      setCurrentTx({
        ...currentTx,
        ...{ txHash, status: "sending" },
      });
      receipt = await provenCall.send().wait({ dontThrowOnRevert: true });
      await walletDB.storeTx({
        contractAddress: currentContract.address,
        txHash,
        fnName,
        receipt,
      });
      setCurrentTx({
        ...currentTx,
        ...{
          txHash,
          status: receipt.status,
          receipt,
          error: receipt.error,
        },
      });
    } catch (e) {
      setCurrentTx({
        ...currentTx,
        ...{
          txHash,
          status: "error",
          error: e.message,
        },
      });
    }

    setIsWorking(false);
  };

  const handleAuthwitFnDataChanged = (
    fnName: string,
    parameters: any[],
    isPrivate: boolean
  ) => {
    setAuthwitFnData({ name: fnName, parameters, isPrivate });
    setOpenCreateAuthwitDialog(true);
  };

  const handleAuthwitCreation = async (
    witness?: AuthWitness,
    alias?: string
  ) => {
    if (witness && alias) {
      await wallet.addAuthWitness(witness);
      await walletDB.storeAuthwitness(witness, undefined, alias);
    }
    setAuthwitFnData({ name: "", parameters: [], isPrivate: false });
    setOpenCreateAuthwitDialog(false);
  };

  return (
    <div css={container}>
      {!contractArtifact ? (
        <div css={dropZoneContainer}>
          <div {...getRootProps({ className: "dropzone" })}>
            <input {...getInputProps()} />
            <Typography>
              Drag 'n' drop some files here, or click to select files
            </Typography>
          </div>
        </div>
      ) : (
        <div css={contractFnContainer}>
          <div css={header}>
            <Typography variant="h2" css={{ marginRight: "4rem" }}>
              {contractArtifact.name}
            </Typography>

            <FormGroup>
              <Input
                type="text"
                placeholder="Search function"
                value={filters.searchTerm}
                onChange={(e) =>
                  setFilters({ ...filters, searchTerm: e.target.value })
                }
                endAdornment={
                  <InputAdornment position="end">
                    <FindInPageIcon />
                  </InputAdornment>
                }
              />
              <div
                css={{
                  display: "flex",
                  flexDirection: "row",
                  marginTop: "0.5rem",
                }}
              >
                <FormControlLabel
                  css={checkBoxLabel}
                  control={
                    <Checkbox
                      checked={filters.private}
                      onChange={(e) =>
                        setFilters({ ...filters, private: e.target.checked })
                      }
                    />
                  }
                  label="Private"
                />
                <FormControlLabel
                  css={checkBoxLabel}
                  control={
                    <Checkbox
                      checked={filters.public}
                      onChange={(e) =>
                        setFilters({ ...filters, public: e.target.checked })
                      }
                    />
                  }
                  label="Public"
                />
                <FormControlLabel
                  css={checkBoxLabel}
                  control={
                    <Checkbox
                      checked={filters.unconstrained}
                      onChange={(e) =>
                        setFilters({
                          ...filters,
                          unconstrained: e.target.checked,
                        })
                      }
                    />
                  }
                  label="Unconstrained"
                />
              </div>
            </FormGroup>
            <div css={{ flexGrow: 1 }}></div>
            {!currentContract && wallet && (
              <>
                <Button
                  variant="contained"
                  css={{ marginRight: "1rem" }}
                  onClick={() => setOpenDeployContractDialog(true)}
                >
                  Deploy
                </Button>
                <Button
                  variant="contained"
                  onClick={() => setOpenRegisterContractDialog(true)}
                >
                  Register
                </Button>
                <DeployContractDialog
                  contractArtifact={contractArtifact}
                  open={openDeployContractDialog}
                  onClose={handleContractCreation}
                />
                <RegisterContractDialog
                  contractArtifact={contractArtifact}
                  open={openRegisterContractDialog}
                  onClose={handleContractCreation}
                />
              </>
            )}
            {currentContract && (
              <>
                <Typography color="text.secondary">
                  {formatFrAsString(currentContract.address.toString())}
                </Typography>
                <CopyToClipboardButton
                  disabled={false}
                  data={currentContract.address.toString()}
                />
                <IconButton
                  onClick={(e) => {
                    setCurrentContract(null);
                    setContractArtifact(null);
                  }}
                >
                  <ClearIcon />
                </IconButton>
              </>
            )}
          </div>
          {contractArtifact.functions
            .filter(
              (fn) =>
                !FORBIDDEN_FUNCTIONS.includes(fn.name) &&
                ((filters.private && fn.functionType === "private") ||
                  (filters.public && fn.functionType === "public") ||
                  (filters.unconstrained &&
                    fn.functionType === "unconstrained")) &&
                (filters.searchTerm === "" ||
                  fn.name.includes(filters.searchTerm))
            )
            .map((fn) => (
              <Card
                key={fn.name}
                variant="outlined"
                sx={{
                  backgroundColor: "primary.light",
                  margin: "1rem",
                }}
              >
                <CardContent sx={{ textAlign: "left" }}>
                  <Typography
                    gutterBottom
                    sx={{ color: "text.secondary", fontSize: 14 }}
                  >
                    {fn.functionType}
                  </Typography>
                  <Typography variant="h5" sx={{ marginBottom: "1rem" }}>
                    {fn.name}
                  </Typography>
                  {fn.parameters.length > 0 && (
                    <>
                      <Typography
                        gutterBottom
                        sx={{
                          color: "text.secondary",
                          fontSize: 14,
                          marginTop: "1rem",
                        }}
                      >
                        Parameters
                      </Typography>
                      <FormGroup row css={{ marginBottom: "1rem" }}>
                        {fn.parameters.map((param, i) => (
                          <FunctionParameter
                            parameter={param}
                            key={param.name}
                            onParameterChange={(newValue) => {
                              handleParameterChange(fn.name, i, newValue);
                            }}
                          />
                        ))}
                      </FormGroup>
                    </>
                  )}

                  {!isWorking && simulationResults[fn.name] !== undefined && (
                    <div css={simulationContainer}>
                      <Typography variant="body1" sx={{ fontWeight: 200 }}>
                        Simulation results:&nbsp;
                      </Typography>
                      {simulationResults[fn.name].success ? (
                        <Typography variant="body1">
                          {simulationResults?.[fn.name]?.data.length === 0
                            ? "-"
                            : simulationResults?.[fn.name].data.toString()}
                        </Typography>
                      ) : (
                        <Typography variant="body1" color="error">
                          {simulationResults?.[fn.name]?.error}
                        </Typography>
                      )}{" "}
                    </div>
                  )}
                  {isWorking ? <CircularProgress size={"1rem"} /> : <></>}
                </CardContent>
                <CardActions>
                  <Button
                    disabled={!wallet || !currentContract || isWorking}
                    color="secondary"
                    variant="contained"
                    onClick={() => simulate(fn.name)}
                    endIcon={<PsychologyIcon />}
                  >
                    Simulate
                  </Button>
                  <Button
                    disabled={
                      !wallet ||
                      !currentContract ||
                      isWorking ||
                      fn.functionType === "unconstrained"
                    }
                    color="secondary"
                    variant="contained"
                    onClick={() => send(fn.name)}
                    endIcon={<SendIcon />}
                  >
                    Send
                  </Button>
                  <Button
                    disabled={
                      !wallet ||
                      !currentContract ||
                      isWorking ||
                      fn.functionType === "unconstrained"
                    }
                    color="secondary"
                    variant="contained"
                    onClick={() =>
                      handleAuthwitFnDataChanged(
                        fn.name,
                        parameters[fn.name],
                        fn.functionType === "private"
                      )
                    }
                    endIcon={<VpnKeyIcon />}
                  >
                    Create authwit
                  </Button>
                </CardActions>
              </Card>
            ))}
        </div>
      )}
      <CreateAuthwitDialog
        open={openCreateAuthwitDialog}
        onClose={handleAuthwitCreation}
        fnName={authwitFnData.name}
        args={authwitFnData.parameters}
        isPrivate={authwitFnData.isPrivate}
      />
    </div>
  );
}
