package main

import (
	"log"
	"os"
	"os/exec"
	"strings"

	"github.com/joho/godotenv"
)

func main() {
	const example_cmd = "go run deploy <network> <simulation=true>"

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
	isSim := true
	if len(args) > 1 {
		isSim = args[1] != "false"
	}

	// Get RPC from env & ensure it exists
	envPath := "ETH_NODE_URI_" + strings.ToUpper(network)
	rpc := os.Getenv(envPath)
	if rpc == "" {
		log.Fatal("RPC not found for network ("+envPath+"): ", network)
	}

	// Build & run command
	dir, _ := os.Getwd()
	forgeArgs := []string{"script", dir + "/script/DeployCurvance.s.sol", network, "--sig", "run(string)", "--rpc-url", rpc, "-vvvv"}
	if isSim {
		log.Printf("Deploying to %s [TEST-RUN]\n", network)
	} else {
		forgeArgs = append(forgeArgs, "--broadcast", "--slow", "--skip-simulation", "--priority-gas-price", "5")
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
