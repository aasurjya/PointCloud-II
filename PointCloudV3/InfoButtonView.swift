import SwiftUI

struct InfoButtonView: View {
    @State private var showInfo = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Info Button
            Button(action: {
                withAnimation(.spring()) {
                    showInfo.toggle()
                }
            }) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
                    .padding()
            }
            
            // Info Card
            if showInfo {
                infoCard
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(1)
            }
        }
    }
    
    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Application Developers")
                .font(.headline)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                DeveloperInfoRow(name: "Praveen Kumar", role: "Lead Developer")
                DeveloperInfoRow(name: "Bijay Das", role: "3D Graphics Engineer")
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(radius: 10)
        )
        .padding(.horizontal)
        .onTapGesture {
            withAnimation(.spring()) {
                showInfo = false
            }
        }
    }
}

struct DeveloperInfoRow: View {
    let name: String
    let role: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .foregroundColor(.blue)
                .font(.title3)
            
            VStack(alignment: .leading) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(role)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct InfoButtonView_Previews: PreviewProvider {
    static var previews: some View {
        InfoButtonView()
            .previewLayout(.sizeThatFits)
    }
}