package main

import (
	"log"
	"os"
	"os/exec"
	"strings"

	"github.com/joho/godotenv"
)

func main() {
	const example_cmd = "go run deploy <network> <part> <simulation=true>"

	// Source .env
	err := godotenv.Load()
	if err != nil {
		log.Fatal("Error loading .env file")
	}

	// Validate private key
	privateKey := os.Getenv("PRIVATE_KEY")
	if privateKey == "" {
		log.Fatal("PRIVATE_KEY not set in .env")
	}
	if privateKey[:2] != "0x" {
		log.Fatal("PRIVATE_KEY must start with 0x")
	}

	// Require forge
	forgePath, err := exec.LookPath("forge")
	if err != nil {
		log.Fatal("Forge not found. Please install foundry.")
	}

	// Require network & setup args
	args := os.Args[1:]
	if len(args) < 1 {
		log.Fatal("Incorrect number of arguments. Example: \n", example_cmd)
	}
	network := args[0]
	part := 1
	if len(args) > 1 {
		switch args[1] {
		case "1":
			part = 1
		case "2":
			part = 2
		case "3":
			part = 3
		default:
			log.Fatal("Invalid part number. Example: \n", example_cmd)
		}
	}
	isSim := true
	if len(args) > 2 {
		isSim = args[2] != "false"
	}

	// Get RPC from env & ensure it exists
	envPath := "ETH_NODE_URI_" + strings.ToUpper(network)
	rpc := os.Getenv(envPath)
	if rpc == "" {
		log.Fatal("RPC not found for network ("+envPath+"): ", network)
	}

	// Build & run command
	dir, _ := os.Getwd()
	var scriptFile string
	switch part {
	case 2:
		scriptFile = "/script/DeployCurvance2.s.sol"
	case 3:
		scriptFile = "/script/DeployCurvance3.s.sol"
	default:
		scriptFile = "/script/DeployCurvance.s.sol"
	}

	forgeArgs := []string{"script", dir + scriptFile, network, "--sig", "run(string)", "--rpc-url", rpc, "-vvvv", "--ffi"}
	if isSim {
		log.Printf("Deploying to %s [TEST-RUN]\n", network)
	} else {
		forgeArgs = append(forgeArgs, "--broadcast", "--skip-simulation", "--priority-gas-price", "15")
		log.Printf("Deploying to %s\n", network)
		log.Println("REMEMBER: UPDATE INDEXER & DAPP WITH NEW CONTRACT ADDRESS")
		log.Println("REMEMBER: UPDATE INDEXER & DAPP WITH NEW CONTRACT ADDRESS")
		log.Println("REMEMBER: UPDATE INDEXER & DAPP WITH NEW CONTRACT ADDRESS")
	}
	cmd := exec.Command(forgePath, forgeArgs...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Run()
}
